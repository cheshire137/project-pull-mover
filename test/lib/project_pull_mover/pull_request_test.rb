# typed: false
# frozen_string_literal: true

require "test_helper"

module ProjectPullMover
  describe "PullRequest" do
    before do
      @out_stream = StringIO.new
      @err_stream = StringIO.new
      @logger = Logger.new(out_stream: @out_stream, err_stream: @err_stream)
      @project_number = 123
      @project_owner = "someUser"
      @failing_test_label = "testfailure"
      @status_field = "StatusField"
      argv = ["-p", @project_number.to_s, "-o", @project_owner, "-t", "user", "-s", @status_field, "-i",
        "MyInProgressID", "-h", "gh", "-f", @failing_test_label, "-a", "notAgainstMainId", "-n", "needsReviewId",
        "-r", "ReadyToDeployId", "-c", "Conflicting_id", "-g", "ignoredId1,ignoredId2", "-m"]
      @options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger)
      @project = Project.new(@options)
      @gh_cli = GhCli.new(options: @options, logger: @logger)
    end

    describe "#set_graphql_data" do
      it "initializes repo and data from GraphQL response" do
        initial_data = {}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.repo
        refute_predicate pull, :draft?
        gql_data = {"pullRequest" => {"isDraft" => true}, "defaultBranchRef" => {"name" => "trunk"}}

        pull.set_graphql_data(gql_data)

        refute_nil pull.repo
        assert_equal "trunk", pull.repo.default_branch
        assert_predicate pull, :draft?
      end
    end

    describe "#number" do
      it "returns PR number from initial data" do
        initial_data = {"content" => {"number" => 456}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal 456, pull.number
      end

      it "returns nil when number not set in initial data hash" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.number

        pull = PullRequest.new({"content" => {}}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.number
      end
    end

    describe "#has_failing_test_label?" do
      it "returns true when failing test label is specified and on the PR" do
        initial_data = {"labels" => ["whee", @failing_test_label, "woo"]}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_predicate pull, :has_failing_test_label?
      end

      it "returns false when failing test label is not specified" do
        argv = ["-p", @project_number.to_s, "-o", @project_owner, "-t", "user", "-s", "StatusField", "-i",
          "MyInProgressID", "-h", "gh", "-a", "notAgainstMainId", "-n", "needsReviewId",
          "-r", "ReadyToDeployId", "-c", "Conflicting_id", "-g", "ignoredId1,ignoredId2", "-m"]
        options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger)
        initial_data = {"labels" => ["whee", @failing_test_label, "woo"]}
        pull = PullRequest.new(initial_data, options: options, project: @project, gh_cli: @gh_cli)

        refute_predicate pull, :has_failing_test_label?
      end

      it "returns false when failing test label is specified but not on the PR" do
        initial_data = {"labels" => ["whee", "woo"]}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        refute_predicate pull, :has_failing_test_label?
      end

      it "returns false when PR has no labels" do
        initial_data = {}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        refute_predicate pull, :has_failing_test_label?
      end
    end

    describe "#labels" do
      it "returns labels from initial data" do
        labels = %w(whee woo)
        initial_data = {"labels" => labels}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)

        assert_equal labels, pull.labels
      end

      it "returns an empty array when labels are not present in initial data" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_empty pull.labels
      end
    end

    describe "#repo_name_with_owner" do
      it "returns full repository name and owner from initial data" do
        initial_data = {"content" => {"repository" => "someone/somerepo"}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "someone/somerepo", pull.repo_name_with_owner
      end

      it "returns nil when repository not given in initial data" do
        initial_data = {"content" => {"foo" => "bar"}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.repo_name_with_owner
      end

      it "returns nil when content not given in initial data" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.repo_name_with_owner
      end
    end

    describe "#repo_owner" do
      it "returns owner login of pull request repository" do
        initial_data = {"content" => {"repository" => "someone/somerepo"}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "someone", pull.repo_owner
      end

      it "returns nil when repository not given in initial data" do
        initial_data = {"content" => {"foo" => "bar"}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.repo_owner
      end

      it "returns nil when content not given in initial data" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.repo_owner
      end
    end

    describe "#repo_name" do
      it "returns name of pull request repository" do
        initial_data = {"content" => {"repository" => "someone/somerepo"}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "somerepo", pull.repo_name
      end

      it "returns nil when repository not given in initial data" do
        initial_data = {"content" => {"foo" => "bar"}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.repo_name
      end

      it "returns nil when content not given in initial data" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.repo_name
      end
    end

    describe "#to_s" do
      it "summarizes PR with repo and number when available" do
        initial_data = {"content" => {"repository" => "someone/somerepo", "number" => 123}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "someone/somerepo#123", pull.to_s
      end

      it "summarizes PR with number when repo is not available" do
        initial_data = {"content" => {"number" => 123}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "pull request #123", pull.to_s
      end

      it "summarizes PR with repo when number is not available" do
        initial_data = {"content" => {"repository" => "someone/somerepo"}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "someone/somerepo pull request", pull.to_s
      end

      it "summarizes PR when repo and number are not available" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "pull request", pull.to_s
      end
    end

    describe "#graphql_field_alias" do
      it "uses repo when known" do
        initial_data = {"content" => {"repository" => "some-one/some-repo", "number" => 123}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal "pullSomeOneSomeRepo123", pull.graphql_field_alias
      end

      it "uses provided index when repo is not known" do
        initial_data = {"content" => {"number" => 123}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli, index: 456)
        assert_equal "pull456123", pull.graphql_field_alias
      end

      it "omits number when not known" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli, index: 1)
        assert_equal "pull1", pull.graphql_field_alias
      end
    end

    describe "#graphql_field" do
      it "returns a field for a GraphQL query using repo details and number" do
        initial_data = {"content" => {"repository" => "someone/some-repo", "number" => 123}}
        pull = PullRequest.new(initial_data, options: @options, project: @project, gh_cli: @gh_cli)

        result = pull.graphql_field

        assert_includes result, "pullSomeoneSomeRepo123: repository(owner: \"someone\", name: \"some-repo\") {"
        assert_includes result, "pullRequest(number: 123) {"
        assert_includes result, "isRequired(pullRequestNumber: 123)"
        assert_includes result, "fieldValueByName(name: \"#{@status_field}\") {"
      end

      it "raises error when repo details or number are missing" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)

        error = assert_raises(PullRequest::MissingRequiredDataError) do
          pull.graphql_field
        end

        assert_equal "Unable to build GraphQL field for pull request, missing required data", error.message
      end
    end
  end
end
