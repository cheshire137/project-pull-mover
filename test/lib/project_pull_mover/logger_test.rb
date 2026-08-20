# typed: false
# frozen_string_literal: true

require "test_helper"

module ProjectPullMover
  describe "Logger" do
    before do
      @out_stream = StringIO.new
      @err_stream = StringIO.new
      @logger = Logger.new(out_stream: @out_stream, err_stream: @err_stream)
    end

    describe "#flush_deferred_warnings" do
      it "logs each warning once with its occurrence count" do
        @logger.defer_warning("Repeated warning")
        @logger.defer_warning("Repeated warning\n")
        @logger.defer_warning("Another warning")

        assert_equal "", @err_stream.string

        @logger.flush_deferred_warnings

        assert_equal "#{Logger::WARNING_PREFIX}Repeated warning (occurred 2 times)\n" \
          "#{Logger::WARNING_PREFIX}Another warning (occurred once)\n", @err_stream.string
      end

      it "does not log blank warnings or warnings already flushed" do
        @logger.defer_warning(" \n")
        @logger.flush_deferred_warnings
        @logger.flush_deferred_warnings

        assert_equal "", @err_stream.string
      end
    end
  end
end
