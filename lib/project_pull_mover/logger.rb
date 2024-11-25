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

    sig { params(out_stream: T.any(IO, StringIO), err_stream: T.any(IO, StringIO)).void }
    def initialize(out_stream:, err_stream:)
      @out_stream = out_stream
      @err_stream = err_stream
    end

    sig { params(content: String).void }
    def error(content)
      @err_stream.puts "#{ERROR_PREFIX}#{content}".force_encoding("UTF-8")
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
