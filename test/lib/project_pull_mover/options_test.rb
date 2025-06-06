# typed: false
# frozen_string_literal: true

require "test_helper"

module ProjectPullMover
  describe Options do
    before do
      @out_stream = StringIO.new
      @err_stream = StringIO.new
      @logger = Logger.new(out_stream: @out_stream, err_stream: @err_stream)
    end

    describe ".parse" do
      it "returns new Options instance when valid" do
        argv = ["-p", "123", "-o", "someorg", "-t", "organization", "-s", "Status", "-i", "abc123"]

        options = Options.parse(file: "project_pull_mover.rb", logger: @logger, argv: argv)

        assert_instance_of Options, options
        assert_equal 123, options.project_number
        assert_equal "someorg", options.project_owner
        assert_equal "organization", options.project_owner_type
        assert_equal "Status", options.status_field
        assert_equal "abc123", options.in_progress_option_id
        assert_equal "", @out_stream.string
        assert_equal "", @err_stream.string
      end

      it "raises exception when arguments are invalid" do
        argv = ["-p", "123", "-o", "someorg", "-t", "repository", "-s", "Status", "-i", "abc123"]

        error = assert_raises(Options::InvalidOptionsError) do
          Options.parse(file: "project_pull_mover.rb", logger: @logger, argv: argv)
        end

        assert_equal "Error: invalid project owner type", error.message
        assert_match(/Usage: project_pull_mover.rb /, @out_stream.string)
        assert_match(/Error: invalid project owner type/, @err_stream.string)
      end

      it "raises exception when argument requiring a value is not given one" do
        error = assert_raises(Options::InvalidOptionsError) do
          Options.parse(file: "ScriptFileName", logger: @logger, argv: ["-p"])
        end

        assert_equal "Error: missing argument: -p", error.message
        assert_match(/Usage: ScriptFileName /, @out_stream.string)
        assert_match(/Error: missing argument: -p/, @err_stream.string)
      end

      it "does not raise for missing required parameters when version flag is passed" do
        options = Options.parse(file: "project_pull_mover.rb", logger: @logger, argv: ["-v"])
        assert_predicate options, :print_version?
      end
    end

    it "parses required arguments" do
      argv = ["-p", "123", "-o", "someorg", "-t", "organization", "-s", "Status", "-i", "abc123"]
      options = Options.new(file: "project_pull_mover.rb", argv: argv, logger: @logger)

      assert options.parse, @err_stream.string

      assert_equal "", @out_stream.string
      assert_equal "", @err_stream.string
      assert_equal 123, options.project_number
      assert_equal "someorg", options.project_owner
      assert_equal "organization", options.project_owner_type
      assert_equal "Status", options.status_field
      assert_equal "abc123", options.in_progress_option_id
      refute_predicate options, :quiet_mode?
      assert_empty options.ignored_option_ids
      assert_nil options.failing_test_label
      assert_empty options.build_names_for_rerun
    end

    it "errors when required arguments are omitted" do
      argv = []
      options = Options.new(file: "project_pull_mover.rb", argv: argv, logger: @logger)

      refute options.parse, @err_stream.string

      assert_match(/Usage: project_pull_mover.rb /, @out_stream.string)
      assert_match(/Error: missing required options/, @err_stream.string)
    end

    it "parses optional arguments" do
      argv = %w(-p 123 -o cheshire137 -t user -i inProgressId -a myNotAgainstMainId -n NeedsReviewID -r
        ready_to_deploy_id -c conflictingId -g ignored1,ignored2,Ignored3 -s Status -h /usr/local/bin/gh -m -f
        failing-test -u cheshire137 --quiet)
      options = Options.new(file: "project_pull_mover.rb", argv: argv, logger: @logger)

      assert options.parse, @err_stream.string

      assert_equal "", @out_stream.string
      assert_equal "", @err_stream.string
      assert_equal 123, options.project_number
      assert_equal "cheshire137", options.project_owner
      assert_equal "user", options.project_owner_type
      assert_equal "Status", options.status_field
      assert_equal "inProgressId", options.in_progress_option_id
      assert_equal "myNotAgainstMainId", options.not_against_main_option_id
      assert_equal "NeedsReviewID", options.needs_review_option_id
      assert_equal "ready_to_deploy_id", options.ready_to_deploy_option_id
      assert_equal "conflictingId", options.conflicting_option_id
      assert_equal %w(ignored1 ignored2 Ignored3), options.ignored_option_ids
      assert_equal "/usr/local/bin/gh", options.gh_path
      assert_predicate options, :quiet_mode?
      assert_equal "failing-test", options.failing_test_label
      assert_equal "cheshire137", options.author
      assert_empty options.build_names_for_rerun
    end
  end
end
