# frozen_string_literal: true

require_relative "../errors"
require_relative "../git"

module Exhale
  module Complexity
    # The comparison base a strict run demands.
    #
    # Without --require-base a run that can't find a base compares
    # nothing and exits 0, listing units over the floor as warnings.
    # A strict run can't do that: a missing base is a setup error, not a
    # clean report. This class resolves the base or raises, and the CLI
    # turns the raise into exit 2.
    #
    # The base is the merge base of the ref and HEAD, the state the
    # branch started from. A ref that moved on since the branch was
    # pushed is still fine: its merge base with HEAD is the branch point.
    class Base
      def initialize(git:, ref: nil)
        @git = git
        @ref = ref
      end

      # The SHA to compare against.
      def resolve
        raise Error, "a comparison base needs a git repository, and #{@git.root} isn't in one" unless @git.repo?

        head = @git.head_sha
        raise Error, "a comparison base needs a commit at HEAD, and this repository has none" unless head

        ref = @ref || default_ref
        raise Error, "no comparison base found: name one with --base REF" if ref.nil?

        sha = @git.commit_sha(ref)
        raise Error, "comparison base #{ref.inspect} names no commit" if sha.nil?

        return first_parent(head, ref) if sha == head

        merge_base(ref, head)
      end

      private

      # The default branch exhale already picks: origin/HEAD, then
      # origin/main, origin/master, main and master.
      def default_ref
        @git.default_branch_ref
      end

      # A push to the default branch leaves HEAD at the merge commit and
      # the remote-tracking ref at that same commit, so there's nothing
      # to compare against. The state before the merge is the merge
      # commit's first parent, and that is the base.
      def first_parent(head, ref)
        parents = @git.parents_of(head)
        raise Error, "comparison base #{ref.inspect} resolves to HEAD — there is nothing to compare" if parents.size < 2

        parents.first
      end

      def merge_base(ref, head)
        sha = @git.merge_base(ref)
        if sha.nil?
          raise Error, "comparison base #{ref.inspect} has no common ancestor with HEAD — there is nothing to compare"
        end
        if sha == head
          raise Error, "comparison base #{ref.inspect} resolves to HEAD — there is nothing to compare"
        end

        sha
      end
    end
  end
end
