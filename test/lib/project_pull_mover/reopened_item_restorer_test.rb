# typed: false
# frozen_string_literal: true

require "test_helper"

module ProjectPullMover
  describe "ReopenedItemRestorer" do
    before do
      @out_stream = StringIO.new
      @logger = Logger.new(out_stream: @out_stream, err_stream: StringIO.new)
      argv = ["-p", "123", "-o", "someUser", "-t", "user", "-s", "Status", "-i", "inProgressId", "-h", "gh"]
      @options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger)
      @project = Project.new(@options)
      @gh_cli = GhCli.new(options: @options, logger: @logger)
      @restorer = ReopenedItemRestorer.new(
        gh_cli: @gh_cli,
        options: @options,
        project: @project,
        logger: @logger,
      )
    end

    it "restores open archived Done items and moves them to In progress" do
      open_content = [
        {"isPullRequest" => false, "number" => 1, "repository" => {"nameWithOwner" => "foo/bar"}},
        {"isPullRequest" => true, "number" => 2, "repository" => {"nameWithOwner" => "foo/bar"}},
        {"isPullRequest" => false, "number" => 3, "repository" => {"nameWithOwner" => "foo/bar"}},
      ]
      @gh_cli.expects(:get_open_project_content).returns(open_content)
      @gh_cli.expects(:make_graphql_api_query).with do |query|
        query.include?("issueOrPullRequest(number: 1)") &&
          query.include?("projectItems(first: 100, includeArchived: true)") &&
          query.include?("fieldValueByName(name: \"Status\")")
      end.returns(
        "content0" => repository_data(archived: true, status: "Done ✅", item_id: "item1"),
        "content1" => repository_data(archived: true, status: "In progress", item_id: "item2"),
        "content2" => repository_data(archived: false, status: "Done", item_id: "item3"),
      )
      @gh_cli.expects(:unarchive_project_item).once.with(project_item_id: "item1", item_name: "foo/bar#1")
      @gh_cli.expects(:set_project_item_status).once.with(
        option_id: "inProgressId",
        project_item_id: "item1",
        project_global_id: "projectId",
        status_field_id: "statusFieldId",
        old_option_name: "Done ✅",
        new_option_name: "In progress",
        pull_name: "foo/bar#1",
      )

      assert_equal 1, @restorer.run
      assert_includes @out_stream.string, "Restored 1 reopened project item to 'In progress'"
    end

    it "does nothing when In progress is not configured" do
      argv = ["-p", "123", "-o", "someUser", "-t", "user", "-s", "Status", "-n", "needsReviewId", "-h", "gh"]
      options = Options.parse(file: "project_pull_mover.rb", argv: argv, logger: @logger)
      restorer = ReopenedItemRestorer.new(
        gh_cli: @gh_cli,
        options: options,
        project: Project.new(options),
        logger: @logger,
      )
      @gh_cli.expects(:get_open_project_content).never

      assert_equal 0, restorer.run
    end

    private

    def repository_data(archived:, status:, item_id:)
      {
        "item" => {
          "projectItems" => {
            "nodes" => [{
              "id" => item_id,
              "isArchived" => archived,
              "project" => {"id" => "projectId", "number" => 123},
              "fieldValueByName" => {
                "name" => status,
                "field" => {"id" => "statusFieldId"},
              },
            }],
          },
        },
      }
    end
  end
end
