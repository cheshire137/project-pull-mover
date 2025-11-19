# typed: false
# frozen_string_literal: true

require "test_helper"

module ProjectPullMover
  describe "GhCli" do
    before do
      @out_stream = StringIO.new
      @err_stream = StringIO.new
      @logger = Logger.new(out_stream: @out_stream, err_stream: @err_stream)
      @project_number = 123
      @project_owner = "someUser"
      @proj_items_limit = 123
      @author = "someAuthor"
      argv = ["-p", @project_number.to_s, "-o", @project_owner, "-t", "user", "-s", "StatusField", "-i",
        "MyInProgressID", "-h", "gh", "-u", @author]
      @options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger,
        proj_items_limit: @proj_items_limit)
      @gh_cli = GhCli.new(options: @options, logger: @logger)
    end

    describe "#apply_pull_request_label" do
      it "runs gh command" do
        GhCli.any_instance.expects(:`).with('gh pr edit 1 --repo "foo/bar" --add-label "foo"')

        @gh_cli.apply_pull_request_label(label_name: "foo", number: 1, repo_nwo: "foo/bar", pull_name: "my test PR")

        assert_equal "#{Logger::LOADING_PREFIX}Applying label 'foo' to my test PR...\n", @out_stream.string
        assert_equal "", @err_stream.string
      end
    end

    describe "#remove_pull_request_label" do
      it "runs gh command" do
        GhCli.any_instance.expects(:`).with('gh pr edit 1 --repo "foo/bar" --remove-label "foo"')

        @gh_cli.remove_pull_request_label(label_name: "foo", number: 1, repo_nwo: "foo/bar", pull_name: "my test PR")

        assert_equal "#{Logger::LOADING_PREFIX}Removing label 'foo' from my test PR...\n", @out_stream.string
        assert_equal "", @err_stream.string
      end
    end

    describe "#rerun_failed_run" do
      it "runs gh command" do
        GhCli.any_instance.expects(:`).with('gh run rerun 1 --failed --repo "foo/bar"')

        @gh_cli.rerun_failed_run(run_id: 1, repo_nwo: "foo/bar", pull_name: "my test PR")

        assert_equal "#{Logger::LOADING_PREFIX}Rerunning failed run 1 for my test PR...\n", @out_stream.string
        assert_equal "", @err_stream.string
      end
    end

    describe "#mark_pull_request_as_draft" do
      it "runs gh command" do
        GhCli.any_instance.expects(:`).with('gh pr ready --undo 1 --repo "foo/bar"')

        @gh_cli.mark_pull_request_as_draft(number: 1, repo_nwo: "foo/bar", pull_name: "my test PR")

        assert_equal "#{Logger::LOADING_PREFIX}Marking my test PR as a draft...\n", @out_stream.string
        assert_equal "", @err_stream.string
      end
    end

    describe "#set_project_item_status" do
      it "runs gh command" do
        option_id = "123abc"
        project_item_id = "456def"
        project_global_id = "789ghi"
        status_field_id = "000bbb"
        GhCli.any_instance.expects(:`).with("gh project item-edit --id #{project_item_id} --project-id " \
          "#{project_global_id} --field-id #{status_field_id} --single-select-option-id #{option_id}")

        @gh_cli.set_project_item_status(
          option_id: option_id,
          project_item_id: project_item_id,
          project_global_id: project_global_id,
          status_field_id: status_field_id,
          old_option_name: "old",
          new_option_name: "new",
          pull_name: "my test PR",
        )

        assert_equal "#{Logger::LOADING_PREFIX}Moving my test PR out of 'old' column to 'new'...",
          @out_stream.string.strip
        assert_equal "", @err_stream.string
      end
    end

    describe "#check_auth_status" do
      it "runs gh command" do
        cmd_output = "yep you're signed in"
        GhCli.any_instance.expects(:`).with("gh auth status").returns(cmd_output)

        @gh_cli.check_auth_status

        assert_equal "#{Logger::INFO_PREFIX}#{cmd_output}", @out_stream.string.strip
        assert_equal "", @err_stream.string
      end
    end

    describe "#get_project_items" do
      it "runs gh command and returns pull request items" do
        pull_item1 = {"content" => {"type" => "PullRequest", "id" => "123"}}
        pull_item2 = {"content" => {"type" => "PullRequest", "id" => "456"}}
        cmd_output = {"items" => [pull_item1, {"content" => {"type" => "Issue"}}, pull_item2]}.to_json
        GhCli.any_instance.expects(:`).with("gh project item-list #{@project_number} --owner #{@project_owner} " \
          "--format json --limit #{@proj_items_limit}").returns(cmd_output)

        result = @gh_cli.get_project_items

        assert_equal 2, result.size
        assert_equal "", @err_stream.string
        assert_equal "#{Logger::INFO_PREFIX}Found 3 items in project", @out_stream.string.strip
        assert_equal([pull_item1, pull_item2], result)
      end

      it "raises error when command returns empty result" do
        cmd_output = ""
        expected_cmd = "gh project item-list #{@project_number} --owner #{@project_owner} " \
          "--format json --limit #{@proj_items_limit}"
        GhCli.any_instance.expects(:`).with(expected_cmd).returns(cmd_output)

        error = assert_raises(GhCli::NoJsonError) { @gh_cli.get_project_items }

        assert_equal "Error: no JSON results for project items; command: #{expected_cmd}", error.message
        assert_equal "", @err_stream.string
        assert_equal "", @out_stream.string
      end

      it "returns empty list when there are no PRs in project" do
        cmd_output = {"items" => [{"content" => {"type" => "Issue"}}]}.to_json
        GhCli.any_instance.expects(:`).with("gh project item-list #{@project_number} --owner #{@project_owner} " \
          "--format json --limit #{@proj_items_limit}").returns(cmd_output)

        result = @gh_cli.get_project_items

        assert_equal 0, result.size
        assert_equal "", @err_stream.string
        assert_equal "#{Logger::INFO_PREFIX}Found 1 item in project\n#{Logger::SUCCESS_PREFIX}No pull requests " \
          "found in project #{@project_number} by @#{@project_owner}", @out_stream.string.strip
      end

      it "handles non-ASCII characters in JSON with ASCII-8BIT encoding" do
        pull_item = {"content" => {"type" => "PullRequest", "id" => "123", "title" => "Fix 🐛 bug"}}
        json_data = {"items" => [pull_item]}.to_json
        # Simulate backtick command returning ASCII-8BIT encoded string
        cmd_output = json_data.dup.force_encoding("ASCII-8BIT")
        GhCli.any_instance.expects(:`).with("gh project item-list #{@project_number} --owner #{@project_owner} " \
          "--format json --limit #{@proj_items_limit}").returns(cmd_output)

        result = @gh_cli.get_project_items

        assert_equal 1, result.size
        assert_equal pull_item, result.first
        assert_equal "", @err_stream.string
      end
    end

    describe "#pulls_by_author_in_project" do
      it "runs gh command on first call when author is set and memoizes the result" do
        expected_result = ["some", "result"]
        cmd_output = expected_result.to_json
        GhCli.any_instance.expects(:`).once.with("gh search prs --author \"#{@author}\" --project " \
          "\"#{@project_owner}/#{@project_number}\" --json \"number,repository\" --limit #{@proj_items_limit} " \
          "--state open").returns(cmd_output)

        result = @gh_cli.pulls_by_author_in_project

        assert_equal expected_result, result
        assert_equal "", @err_stream.string
        assert_equal "#{Logger::INFO_PREFIX}Looking up open pull requests by @#{@author} in project...",
          @out_stream.string.strip

        GhCli.any_instance.expects(:`).never

        result = @gh_cli.pulls_by_author_in_project

        assert_equal expected_result, result
      end

      it "returns nil when author is not set" do
        GhCli.any_instance.expects(:`).never
        argv = ["-p", @project_number.to_s, "-o", @project_owner, "-t", "user", "-s", "StatusField", "-i",
          "MyInProgressID", "-h", "gh"]
        options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger)
        gh_cli = GhCli.new(options: options, logger: @logger)

        assert_nil gh_cli.pulls_by_author_in_project
      end

      it "handles non-ASCII characters in JSON with ASCII-8BIT encoding" do
        expected_result = [{"number" => 1, "repository" => {"nameWithOwner" => "user/repo"}, "title" => "Add 🎉 feature"}]
        json_data = expected_result.to_json
        # Simulate backtick command returning ASCII-8BIT encoded string
        cmd_output = json_data.dup.force_encoding("ASCII-8BIT")
        GhCli.any_instance.expects(:`).once.with("gh search prs --author \"#{@author}\" --project " \
          "\"#{@project_owner}/#{@project_number}\" --json \"number,repository\" --limit #{@proj_items_limit} " \
          "--state open").returns(cmd_output)

        result = @gh_cli.pulls_by_author_in_project

        assert_equal expected_result, result
        assert_equal "", @err_stream.string
      end
    end

    describe "#author_pull_numbers_by_repo_nwo" do
      it "runs gh command when author is set" do
        repo_nwo1 = "foo/bar"
        repo_nwo2 = "baz/qux"
        cmd_output = [
          {"repository" => {"nameWithOwner" => repo_nwo1}, "number" => 1},
          {"repository" => {"nameWithOwner" => repo_nwo2}, "number" => 123},
          {"repository" => {"nameWithOwner" => repo_nwo1}, "number" => 2},
        ].to_json
        GhCli.any_instance.expects(:`).once.with("gh search prs --author \"#{@author}\" --project " \
          "\"#{@project_owner}/#{@project_number}\" --json \"number,repository\" --limit #{@proj_items_limit} " \
          "--state open").returns(cmd_output)

        result = @gh_cli.author_pull_numbers_by_repo_nwo

        assert_equal 2, result.size
        assert_equal({repo_nwo1 => [1, 2], repo_nwo2 => [123]}, result)
      end

      it "returns nil when no author is set" do
        GhCli.any_instance.expects(:`).never
        argv = ["-p", @project_number.to_s, "-o", @project_owner, "-t", "user", "-s", "StatusField", "-i",
          "MyInProgressID", "-h", "gh"]
        options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger)
        gh_cli = GhCli.new(options: options, logger: @logger)

        assert_nil gh_cli.author_pull_numbers_by_repo_nwo
      end
    end

    describe "#make_graphql_api_query" do
      it "runs gh command and handles successful response" do
        data = {"foo" => "bar"}
        cmd_output = {"data" => data}.to_json
        graphql_query = "some query"
        GhCli.any_instance.expects(:`).once.with("gh api graphql -f query='#{graphql_query}'").returns(cmd_output)

        result = @gh_cli.make_graphql_api_query(graphql_query)

        assert_equal data, result
      end

      it "runs gh command and handles error response with 'errors' field" do
        cmd_output = {"errors" => [{"message" => "o noes"}, {"message" => "it failed"}]}.to_json
        graphql_query = "some query"
        GhCli.any_instance.expects(:`).once.with("gh api graphql -f query='#{graphql_query}'").returns(cmd_output)

        error = assert_raises(GhCli::GraphqlApiError) { @gh_cli.make_graphql_api_query(graphql_query) }

        assert_equal "Error: no data returned from the GraphQL API: o noes\nit failed", error.message
      end

      it "runs gh command and handles error response without 'errors' field" do
        cmd_output = {"foo" => "bar"}.to_json
        graphql_query = "some query"
        GhCli.any_instance.expects(:`).once.with("gh api graphql -f query='#{graphql_query}'").returns(cmd_output)

        error = assert_raises(GhCli::GraphqlApiError) { @gh_cli.make_graphql_api_query(graphql_query) }

        assert_equal "Error: no data returned from the GraphQL API: {\"foo\"=>\"bar\"}", error.message
      end

      it "handles non-ASCII characters in JSON with ASCII-8BIT encoding" do
        data = {"project" => {"name" => "Test 🚀 Project"}}
        json_data = {"data" => data}.to_json
        # Simulate backtick command returning ASCII-8BIT encoded string
        cmd_output = json_data.dup.force_encoding("ASCII-8BIT")
        graphql_query = "some query"
        GhCli.any_instance.expects(:`).once.with("gh api graphql -f query='#{graphql_query}'").returns(cmd_output)

        result = @gh_cli.make_graphql_api_query(graphql_query)

        assert_equal data, result
      end
    end
  end
end
