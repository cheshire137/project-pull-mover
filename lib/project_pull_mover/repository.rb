# typed: true
# frozen_string_literal: true
# encoding: utf-8

module ProjectPullMover
  class Repository
    extend T::Sig

    sig { params(gql_data: T::Hash[T.untyped, T.untyped], failing_test_label_name: T.nilable(String)).void }
    def initialize(gql_data, failing_test_label_name: nil)
      @gql_data = gql_data
      @raw_failing_test_label_name = failing_test_label_name
    end

    sig { returns String }
    def default_branch
      @default_branch ||= @gql_data["defaultBranchRef"]["name"]
    end
  end
end
