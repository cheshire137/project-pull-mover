# typed: true
# frozen_string_literal: true
# encoding: utf-8

require 'stringio'

module ProjectPullMover
  class Logger
    extend T::Sig

    ERROR_PREFIX = "❌ "
    LOADING_PREFIX = "⏳ "
    SUCCESS_PREFIX = "✅ "
    INFO_PREFIX = "ℹ️ "
    WARNING_PREFIX = "⚠️ "

    sig { params(out_stream: T.any(IO, StringIO), err_stream: T.any(IO, StringIO)).void }
    def initialize(out_stream:, err_stream:)
      @out_stream = out_stream
      @err_stream = err_stream
      @deferred_warnings = T.let(Hash.new(0), T::Hash[String, Integer])
    end

    sig { params(content: String).void }
    def error(content)
      @err_stream.puts "#{ERROR_PREFIX}#{content}".force_encoding("UTF-8")
    end

    sig { params(content: String).void }
    def defer_warning(content)
      content = content.strip
      return if content.empty?

      @deferred_warnings[content] = (@deferred_warnings[content] || 0) + 1
    end

    sig { void }
    def flush_deferred_warnings
      @deferred_warnings.each do |content, count|
        occurrences = count == 1 ? "occurred once" : "occurred #{count} times"
        @err_stream.puts "#{WARNING_PREFIX}#{content} (#{occurrences})".force_encoding("UTF-8")
      end
      @deferred_warnings.clear
    end

    sig { params(content: String).void }
    def loading(content)
      @out_stream.puts "#{LOADING_PREFIX}#{content}".force_encoding("UTF-8")
    end

    sig { params(content: String).void }
    def success(content)
      @out_stream.puts "#{SUCCESS_PREFIX}#{content}".force_encoding("UTF-8")
    end

    sig { params(content: String).void }
    def info(content)
      @out_stream.puts "#{INFO_PREFIX}#{content}".force_encoding("UTF-8")
    end
  end
end
