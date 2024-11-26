# typed: true
# frozen_string_literal: true
# encoding: utf-8

module ProjectPullMover
  class Repository
    extend T::Sig

    sig { params(gql_data: T::Hash[T.untyped, T.untyped]).void }
    def initialize(gql_data)
      @gql_data = gql_data
    end

    sig { returns String }
    def default_branch
      @default_branch ||= @gql_data["defaultBranchRef"]["name"]
    end
  end
end
