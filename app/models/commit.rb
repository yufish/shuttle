# Copyright 2013 Square Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

require 'fileutils'

# A state in a {Project}'s source history. A commit, in the context of this
# program, is a point in the history of a Project that is either approved or not
# approved for release, from a localization standpoint.
#
# Each new Commit, when created, is scanned for importable blobs. These blobs
# are scraped for {Key Keys} and {Translation Translations}, which are added to
# the corpus, and new {Blob} records are created. If the commit shares blobs
# with an already-imported commit, the blob is skipped.
#
# Existing keys are updated with new base translations, if the copy has changed,
# and translations are marked as pending review. Translations are created for
# any new Keys and marked as pending translation and review.
#
# Once all Translations of a Commit are translated and reviewed,
# that Commit is considered localized for that locale. Once all required
# locales have been reviewed, the Commit is ready for release. `after_save`
# hooks on {Translation} automatically manage the `ready` field, and the
# various workers method manage the `loading` field.
#
# Keys are child to a Project, not a Commit. A Commit has a many-to-many
# association that tracks which keys can be found under that commit.
#
# Associations
# ============
#
# |                |                                                      |
# |:---------------|:-----------------------------------------------------|
# | `project`      | The {Project} this is a Commit under.                |
# | `keys`         | All the {Key Keys} found in this Commit.             |
# | `translations` | The {Translation Translations} found in this Commit. |
#
# Properties
# ==========
#
# |                |                                                                                                                            |
# |:---------------|:---------------------------------------------------------------------------------------------------------------------------|
# | `committed_at` | The time this commit was made.                                                                                             |
# | `message`      | The commit message.                                                                                                        |
# | `ready`        | If `true`, all Keys under this Commit are marked as ready.                                                                 |
# | `revision`     | The SHA1 for this commit.                                                                                                  |
# | `loading`      | If `true`, there is at least one {BlobImporter} processing this Commit. |

class Commit < ActiveRecord::Base
  # @return [true, false] If `true`, does not perform an import after creating
  #   the Commit. Use this to avoid the overhead of making an HTTP request and
  #   spawning a worker for situations where Commits are being added in bulk.
  attr_accessor :skip_import

  belongs_to :project, inverse_of: :commits
  has_and_belongs_to_many :keys, uniq: true
  has_many :translations, through: :keys

  validates :project,
            presence: true
  validates :revision_raw,
            presence:   true,
            uniqueness: {scope: :project_id}
  validates :message,
            presence: true,
            length:   {maximum: 256}
  validates :committed_at,
            presence:   true,
            timeliness: {type: :time}

  extend GitObjectField
  git_object_field :revision,
                   git_type:        :commit,
                   repo:            ->(c) { c.project.try(:repo) },
                   repo_must_exist: true,
                   scope:           :for_revision

  before_validation :load_message, on: :create
  before_validation(on: :create) do |obj|
    obj.message = obj.message.truncate(256) if obj.message
  end

  after_commit(on: :create) do |commit|
    CommitImporter.perform_once(commit.id) unless commit.skip_import
  end
  after_commit :compile_and_cache_or_clear, on: :update

  attr_accessible :revision, :message, :committed_at, :skip_import,
                  :skip_sha_check, as: :system
  attr_accessible :revision, as: :admin
  attr_readonly :revision, :message

  # @private
  def to_param() revision end

  # Calculates the value of the `ready` field and saves the record.

  def recalculate_ready!
    ready = !keys.where(ready: false).exists?
    update_column :ready, ready
    compile_and_cache_or_clear(ready)
  end

  # Returns `true` if all Translations applying to this commit have been
  # translated to this locale and reviewed.
  #
  # @param [Locale] locale The locale.
  # @return [true, false] Whether localization is complete for that locale.

  def localized?(locale)
    translations.where(rfc5646_locale: locale.rfc5646).where('approved IS NOT TRUE').count == 0
  end

  # Recursively locates blobs in this commit, creates Blobs for each of them if
  # necessary, and calls {Blob#import_strings} on them.
  #
  # @param [Hash] options Import options.
  # @option options [Locale] locale The locale to assume the base copy is
  #   written in (by default it's the Project's base locale).
  # @option options [true, false] inline (false) If `true`, does not spawn
  #   Sidekiq workers to perform the import in parallel.
  # @option options [true, false] force (false) If `true`, blobs will be
  #   re-scanned for keys even if they have already been scanned.
  # @raise [CommitNotFoundError] If the commit could not be found in the Git
  #   repository.

  def import_strings(options={})
    raise CommitNotFoundError, "Commit no longer exists: #{revision}" unless commit!
    keys.clear
    import_tree commit!.gtree, '', options
    update_stats_at_end_of_loading if options[:inline]
  end

  # Returns a commit object used to interact with Git.
  #
  # @return [Git::Object::Commit, nil] The commit object.

  def commit
    project.repo.object(revision)
  end

  # Same as {#commit}, but fetches the upstream repository changes if the commit
  # is unrecognized.
  #
  # @return [Git::Object::Commit, nil] The commit object.

  def commit!
    project.repo do |r|
      r.object(revision) || (r.fetch && r.object(revision))
    end
  end

  # @return [String, nil] The URL to this commit on GitHub or GitHub Enterprise,
  #   or `nil` if the URL could not be determined.

  def github_url
    if project.repository_url =~ /^git@github\.com:([^\/]+)\/(.+)\.git$/ ||
        project.repository_url =~ /https:\/\/\w+@github\.com\/([^\/]+)\/(.+)\.git/ ||
        project.repository_url =~ /git:\/\/github\.com\/([^\/]+)\/(.+)\.git/ # GitHub
      "https://github.com/#{$1}/#{$2}/commit/#{revision}"
    end
  end

  # @private
  def as_json(options=nil)
    options ||= {}

    options[:methods] = Array.wrap(options[:methods])
    options[:methods] << :github_url << :revision

    options[:except] = Array.wrap(options[:except])
    options[:except] << :revision_raw

    super options
  end

  # Recalculates the number of approved Translations across all required under
  # this Commit. Normally this is done using hooks, but can be forced here.

  def translations_done!
    self.translations_done = translations.not_base.where(approved: true, rfc5646_locale: project.required_locales.map(&:rfc5646)).count
  end

  # Recalculates the number of Translations across all required locales under
  # this Commit. Normally this is done using hooks, but can be forced here.

  def translations_total!
    self.translations_total = translations.not_base.where(rfc5646_locale: project.required_locales.map(&:rfc5646)).count
  end

  # @return [Float] The fraction of Translations under this Commit that are
  #   approved, across all required locales.

  def fraction_done
    translations_done/translations_total.to_f
  end

  # Recalculates the total number of translatable base strings applying to this
  # Commit. Normally this is done using hooks, but can be forced here.

  def strings_total!
    self.strings_total = keys.count
  end

  # Adds a worker to the loading list. This commit, if not already loading,
  # will be marked as loading until this and all other added workers call
  # {#remove_worker!}.
  #
  # @param [String] jid A unique identifier for this worker.

  def add_worker!(jid)
    update_column :loading, true
    Shuttle::Redis.sadd "import:#{revision}", jid
  end

  # Removes a worker from the loading list. This Commit will not be marked as
  # loading if this was the last worker. Also recalculates Commit statistics if
  # this was the last worker.
  #
  # @param [String] jid A unique identifier for this worker.
  # @see #add_worker!

  def remove_worker!(jid)
    loading_was = self.loading

    Shuttle::Redis.srem "import:#{revision}", jid
    loading = (Shuttle::Redis.scard("import:#{revision}") > 0)
    update_column :loading, loading

    update_stats_at_end_of_loading if loading_was && !loading
  end

  # Removes all workers from the loading list, marks the Commit as not loading,
  # and recalculates Commit statistics if the Commit was previously loading.
  # This method should be used to fix "stuck" Commits.

  def clear_workers!
    Shuttle::Redis.del "import:#{revision}"
    if loading?
      update_column :loading, false
      update_stats_at_end_of_loading if loading_was && !loading
    end
  end

  def all_translations_entered_for_locale?(locale)
    translations.not_base.where(rfc5646_locale: locale.rfc5646, translated: false).count == 0
  end

  def all_translations_approved_for_locale?(locale)
    translations.not_base.where(rfc5646_locale: locale.rfc5646, approved: false).count == 0
  end

  private

  def load_message
    self.message ||= commit!.message
    true
  end

  #TODO this does not cache across servers; would need to use S3 or something
  def compile_and_cache_or_clear(force=false)
    return unless force || ready_changed?

    # clear out existing cache entries if present
    Exporter::Base.implementations.each do |exporter|
      FileUtils.rm_f ManifestPrecompiler.new.path(self, exporter.request_mime)
    end
    FileUtils.rm_f LocalizePrecompiler.new.path(self)

    # if ready, generate new cache entries
    if ready?
      LocalizePrecompiler.perform_once(id) if project.cache_localization?
      project.cache_manifest_formats.each do |format|
        ManifestPrecompiler.perform_once id, format
      end
    end
  end

  def import_tree(tree, path, options={})
    tree.blobs.each do |name, blob|
      blob_path = "#{path}/#{name}"

      Shuttle::Redis.del("keys_for_blob:#{@blob.sha}") if options[:force]

      if options[:inline]
        BlobImporter.new.perform project.id, blob.sha, blob_path, id, options[:locale].try(:rfc5646)
      else
        add_worker! BlobImporter.perform_once(project.id, blob.sha, blob_path, id, options[:locale].try(:rfc5646))
      end
    end

    tree.trees.each do |name, subtree|
      import_tree subtree, "#{path}/#{name}", options
    end
  end

  def update_stats_at_end_of_loading
    # the readiness hooks were all disabled, so now we need to go through and
    # calculate readiness and stats. since we could have altered the readiness
    # of other commits associated with translations we just imported, we need to
    # do this for all commits that could potentially be affected

    # first we do it for this commit, so we can set loading to false ASAP
    CommitStatsRecalculator.new.perform id

    # then we do it for everyone else
    project.commits.find_each do |commit|
      next if commit.id == id
      CommitStatsRecalculator.perform_once commit.id
    end
  end
end