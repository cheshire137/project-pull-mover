# typed: true
# frozen_string_literal: true

require_relative "data_loader"
require_relative "logger"
require_relative "options"
require_relative "utils"

module ProjectPullMover
  class PullRequestMover
    extend T::Sig

    include Utils

    sig { params(data: DataLoader::Result, options: Options, logger: Logger).void }
    def self.run(data:, options:, logger:)
      new(data: data, options: options, logger: logger).run
    end

    sig { params(data: DataLoader::Result, options: Options, logger: Logger).void }
    def initialize(data:, options:, logger:)
      @data = data
      @options = options
      @logger = logger
    end

    sig { void }
    def run
      project_pulls = @data.pull_requests
      total_status_changes_by_new_status = Hash.new(0)
      total_labels_applied_by_name = Hash.new(0)
      total_labels_removed_by_name = Hash.new(0)

      project_pulls.each do |pull|
        new_pull_status_option_name = pull.change_status_if_necessary
        if new_pull_status_option_name
          total_status_changes_by_new_status[new_pull_status_option_name] += 1
        end

        applied_label_name = pull.apply_label_if_necessary
        if applied_label_name
          total_labels_applied_by_name[applied_label_name] += 1
        end

        removed_label_name = pull.remove_label_if_necessary
        if removed_label_name
          total_labels_removed_by_name[removed_label_name] += 1
        end
      end

      any_changes = (total_status_changes_by_new_status.values.sum +
        total_labels_applied_by_name.values.sum +
        total_labels_removed_by_name.values.sum) > 0

      if any_changes
        message_pieces = []

        total_status_changes_by_new_status.each do |new_status, count|
          units = count == 1 ? "pull request" : "pull requests"
          first_letter = message_pieces.size < 1 ? "M" : "m"
          message_pieces << "#{first_letter}oved #{count} #{units} to '#{new_status}'"
        end

        total_labels_applied_by_name.each do |label_name, count|
          units = count == 1 ? "pull request" : "pull requests"
          first_letter = message_pieces.size < 1 ? "A" : "a"
          message_pieces << "#{first_letter}pplied '#{label_name}' to #{count} #{units}"
        end

        total_labels_removed_by_name.each do |label_name, count|
          units = count == 1 ? "pull request" : "pull requests"
          first_letter = message_pieces.size < 1 ? "R" : "r"
          message_pieces << "#{first_letter}emoved '#{label_name}' from #{count} #{units}"
        end

        message = message_pieces.join(", ")
        @logger.info(message) unless quiet_mode?
        send_desktop_notification(content: message, title: @data.project.title)
      else
        @logger.info("No pull requests needed a different status or a label change") unless quiet_mode?
      end
    end

    private

    sig {  params(content: String, title: String).void }
    def send_desktop_notification(content:, title:)
      has_osascript = which("osascript")
      if has_osascript
        quote_regex = /["']/
        content = content.gsub(quote_regex, "")
        title = title.gsub(quote_regex, "")
        `osascript -e 'display notification "#{content}" with title "#{title}"'`
      end
    end

    sig { returns(T::Boolean) }
    def quiet_mode?
      @options.quiet_mode?
    end
  end
end
