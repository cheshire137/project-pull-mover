#!/usr/bin/env ruby
# encoding: utf-8

module ProjectPullMover
  module Utils
    def output_error_message(content)
      STDERR.puts "❌ #{content}".force_encoding("UTF-8")
    end

    def output_loading_message(content)
      puts "⏳ #{content}".force_encoding("UTF-8")
    end

    def output_success_message(content)
      puts "✅ #{content}".force_encoding("UTF-8")
    end

    def output_info_message(content)
      puts "ℹ️ #{content}".force_encoding("UTF-8")
    end

    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable?(exe) && !File.directory?(exe)
        end
      end
      nil
    end

    def send_desktop_notification(content:, title:)
      has_osascript = which("osascript")
      if has_osascript
        quote_regex = /["']/
        content = content.gsub(quote_regex, "")
        title = title.gsub(quote_regex, "")
        `osascript -e 'display notification "#{content}" with title "#{title}"'`
      end
    end

    def replace_hyphens(str)
      str.split("-").map(&:capitalize).join("")
    end
  end
end
