# typed: true
# frozen_string_literal: true
# encoding: utf-8

module ProjectPullMover
  class Logger
    extend T::Sig

    sig { params(out_stream: IO, err_stream: IO).void }
    def initialize(out_stream:, err_stream:)
      @out_stream = out_stream
      @err_stream = err_stream
    end

    sig { params(content: String).void }
    def error(content)
      @err_stream.puts "❌ #{content}".force_encoding("UTF-8")
    end

    sig { params(content: String).void }
    def loading(content)
      @out_stream.puts "⏳ #{content}".force_encoding("UTF-8")
    end

    sig { params(content: String).void }
    def success(content)
      @out_stream.puts "✅ #{content}".force_encoding("UTF-8")
    end

    sig { params(content: String).void }
    def info(content)
      @out_stream.puts "ℹ️ #{content}".force_encoding("UTF-8")
    end
  end
end
