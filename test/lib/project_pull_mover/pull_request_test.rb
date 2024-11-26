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
      argv = ["-p", @project_number.to_s, "-o", @project_owner, "-t", "user", "-s", "StatusField", "-i",
        "MyInProgressID", "-h", "gh", "-f", "testfailure", "-a", "notAgainstMainId", "-n", "needsReviewId",
        "-r", "ReadyToDeployId", "-c", "Conflicting_id", "-g", "ignoredId1,ignoredId2", "-m"]
      @options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger)
      @project = Project.new(@options)
      @gh_cli = GhCli.new(options: @options, logger: @logger)
    end

    describe "#set_graphql_data" do
      it "initializes repo and data from GraphQL response" do
        pull_item_data = {}
        pull = PullRequest.new(pull_item_data, options: @options, project: @project, gh_cli: @gh_cli)
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
        pull_item_data = {"content" => {"number" => 456}}
        pull = PullRequest.new(pull_item_data, options: @options, project: @project, gh_cli: @gh_cli)
        assert_equal 456, pull.number
      end

      it "returns nil when number not set in initial data hash" do
        pull = PullRequest.new({}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.number

        pull = PullRequest.new({"content" => {}}, options: @options, project: @project, gh_cli: @gh_cli)
        assert_nil pull.number
      end
    end
  end
end
