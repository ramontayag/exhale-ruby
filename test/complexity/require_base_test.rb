# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require "json"
require "exhale/cli"

# `exhale complexity --require-base` against real git graphs, contract/cli/README.md.
#
# The flag makes a comparison base mandatory: a run that can't resolve one
# exits 2 instead of passing on warnings. Every case here builds a real
# repository and runs the real CLI, so the check reads git the way CI does.
class RequireBaseTest < Minitest::Test
  ORDER = <<~RUBY
    class Order
      def total(lines)
        lines.sum { |line| line.amount }
      end
    end
  RUBY

  # A method with `score` modifier ifs, so it scores `score` points.
  def method(name, score)
    lines = (1..score).map { |k| "    s#{k}(a) if a.r#{k}?\n" }
    "  def #{name}(a)\n#{lines.join}    a\n  end\n"
  end

  def setup
    @dir = Dir.mktmpdir("exhale-require-base")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # Runs git in the test's repository and fails the test when the command
  # doesn't succeed: a setup command that fails silently makes a missing
  # ref look like a graph problem.
  def git(*args, dir: @dir)
    env = { "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z" }
    out, status = Open3.capture2e(env, "git", "-C", dir, *args)
    raise out unless status.success?

    out.strip
  end

  def write(path, content, dir: @dir)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit(message, dir: @dir)
    git("add", "-A", dir: dir)
    git("commit", "-q", "--allow-empty", "-m", message, dir: dir)
  end

  # A repository with one commit on main and no remote-tracking ref.
  def init_repo
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    git("config", "commit.gpgsign", "false")
    write(".gitignore", "tmp/\n")
    write("app/models/order.rb", ORDER)
    commit("base")
  end

  def exhale(*args, dir: @dir)
    out = StringIO.new
    err = StringIO.new
    code = Exhale::CLI.new([*args, "--root", dir], out: out, err: err).run
    [code, out.string, err.string]
  end

  def complexity(*args, dir: @dir)
    exhale("complexity", *args, dir: dir)
  end

  # ---- a base that resolves ------------------------------------------------

  # Contract: cli/L6
  def test_an_explicit_base_that_resolves_compares_against_it
    init_repo
    git("checkout", "-q", "-b", "pr")
    write("app/models/order.rb", ORDER.sub("def total(lines)", "def total(lines)\n        lines.each { |l| l }"))
    commit("change")

    code, out, err = complexity("--base", "main", "--require-base")
    assert_equal 0, code, err
    assert_match(/exhale complexity/, out)
  end

  # The default ref is the one exhale already picks: origin/HEAD, then
  # origin/main, origin/master, main, master.
  # Contract: cli/L6
  def test_the_default_ref_is_origin_head_when_it_is_set
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("change")
    git("update-ref", "refs/remotes/origin/trunk", "main")
    git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")

    code, _, err = complexity("--require-base")
    assert_equal 0, code, err
  end

  # Contract: cli/L6
  def test_the_default_ref_is_origin_main_when_origin_head_is_not_set
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("change")
    git("update-ref", "refs/remotes/origin/main", "main")

    code, _, err = complexity("--require-base")
    assert_equal 0, code, err
  end

  # ---- a base that doesn't resolve -----------------------------------------

  # Contract: cli/L6
  def test_a_missing_explicit_base_exits_two
    init_repo
    code, out, err = complexity("--base", "no-such-ref", "--require-base")

    assert_equal 2, code
    assert_empty out
    assert_match(/comparison base "no-such-ref" names no commit/, err)
  end

  # Contract: cli/L6
  def test_no_default_ref_exits_two
    # The default branch candidates are origin/HEAD, origin/main,
    # origin/master, main and master. A branch named none of them leaves
    # the run with no default to fall back on.
    git("init", "-q", "-b", "trunk")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    git("config", "commit.gpgsign", "false")
    write(".gitignore", "tmp/\n")
    write("app/models/order.rb", ORDER)
    commit("base")

    code, out, err = complexity("--require-base")

    assert_equal 2, code
    assert_empty out
    assert_match(/no comparison base found: name one with --base REF/, err)
  end

  # Contract: cli/L6
  def test_no_git_repository_exits_two
    plain = Dir.mktmpdir("exhale-require-base-plain")
    write("app/models/order.rb", ORDER, dir: plain)

    code, out, err = complexity("--require-base", dir: plain)

    assert_equal 2, code
    assert_empty out
    assert_match(/git repository/, err)
  ensure
    FileUtils.rm_rf(plain)
  end

  # An unborn HEAD has no commit to compare against.
  # Contract: cli/L6
  def test_an_unborn_head_exits_two
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")

    code, out, err = complexity("--require-base")

    assert_equal 2, code
    assert_empty out
    assert_match(/HEAD/, err)
  end

  # A ref with no common ancestor with HEAD leaves nothing to compare.
  # Contract: cli/L6
  def test_a_base_with_unrelated_history_exits_two
    init_repo
    git("checkout", "-q", "--orphan", "unrelated")
    git("rm", "-rqf", ".")
    write("app/models/order.rb", ORDER)
    commit("unrelated history")
    git("checkout", "-q", "main")

    code, out, err = complexity("--base", "unrelated", "--require-base")

    assert_equal 2, code
    assert_empty out
    assert_match(/common ancestor/, err)
  end

  # A plain commit that equals HEAD has nothing to compare against.
  # Contract: cli/L6
  def test_a_base_that_equals_an_ordinary_head_exits_two
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("change")

    code, out, err = complexity("--base", "HEAD", "--require-base")

    assert_equal 2, code
    assert_empty out
    assert_match(/nothing to compare/, err)
  end

  # A base that isn't HEAD but whose merge base is HEAD has nothing to
  # compare against either: HEAD is an ancestor of the base, so the
  # branch started from the base's own past.
  # Contract: cli/L6
  def test_a_base_whose_merge_base_is_head_exits_two
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("change")
    # main takes pr's commit and moves on, so HEAD is an ancestor of main.
    git("checkout", "-q", "main")
    git("merge", "-q", "--ff-only", "pr")
    commit("main moves on")
    git("checkout", "-q", "pr")

    code, out, err = complexity("--base", "main", "--require-base")

    assert_equal 2, code
    assert_empty out
    assert_match(/comparison base "main" resolves to HEAD — there is nothing to compare/, err)
  end

  # ---- a base that moved ahead ---------------------------------------------

  # The base branch moves on after the branch was pushed, so origin/main
  # is no longer an ancestor of HEAD. The merge base is the branch point.
  # Contract: cli/L6
  def test_a_base_that_moved_ahead_compares_against_the_merge_base
    init_repo
    branch_point = git("rev-parse", "main")
    git("checkout", "-q", "-b", "pr")
    write("app/models/order.rb", "class Order\n#{method('total', 9)}end\n")
    commit("change")
    git("checkout", "-q", "main")
    write("app/models/other.rb", "class Other\n  def x = 1\nend\n")
    commit("main moves on")
    git("update-ref", "refs/remotes/origin/main", "main")
    git("checkout", "-q", "pr")

    code, out, err = complexity("--require-base", "--format", "json")

    assert_equal 1, code, err
    report = JSON.parse(out)
    assert_equal branch_point, report["base"]
    assert_equal "raised", report["units"].find { |u| u["identity"] == "Order#total" }["label"]
  end

  # ---- the first-parent fallback -------------------------------------------

  # A push to the default branch leaves HEAD at the merge commit and the
  # remote-tracking ref at the same commit. The base is then the merge
  # commit's first parent: the state of the branch before the merge.
  # Contract: cli/L6
  def test_a_base_at_a_merge_commit_uses_the_first_parent
    init_repo
    before = git("rev-parse", "HEAD")
    git("checkout", "-q", "-b", "feature")
    write("app/models/feature.rb", "class Feature\n  def x = 1\nend\n")
    commit("feature work")
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "feature", "-m", "Merge feature")
    git("update-ref", "refs/remotes/origin/main", "HEAD")

    code, out, err = complexity("--require-base", "--format", "json")

    assert_equal 0, code, err
    assert_equal before, JSON.parse(out)["base"]
  end

  # The fallback is for merge commits only: a plain commit at HEAD still
  # has nothing to compare against.
  # Contract: cli/L6
  def test_a_base_at_a_merge_commit_without_a_second_parent_still_exits_two
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("change")
    git("update-ref", "refs/remotes/origin/main", "HEAD")

    code, out, err = complexity("--require-base")

    assert_equal 2, code
    assert_empty out
    assert_match(/nothing to compare/, err)
  end

  # ---- exit codes ----------------------------------------------------------

  # A clean run under the flag exits 0, and a regression exits 1: the
  # flag only changes what a missing base does.
  # Contract: cli/L6
  def test_a_clean_run_exits_zero_and_a_regression_exits_one
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("no change")

    code, _, err = complexity("--base", "main", "--require-base")
    assert_equal 0, code, err

    write("app/models/order.rb", "class Order\n#{method('total', 9)}end\n")
    commit("raise")

    code, out, err = complexity("--base", "main", "--require-base")
    assert_equal 1, code, err
    assert_match(/raised|introduced/, out)
  end

  # ---- the flag changes nothing without it --------------------------------

  # Without the flag the run keeps its old behaviour: a missing base is a
  # warning, and the run exits 0. Without --require-base the run compares
  # nothing and says so; with it the run refuses to start.
  # Contract: cli/L6
  def test_without_the_flag_a_missing_default_base_is_only_a_warning
    git("init", "-q", "-b", "trunk")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    git("config", "commit.gpgsign", "false")
    write(".gitignore", "tmp/\n")
    write("app/models/order.rb", "class Order\n#{method('total', 9)}end\n")
    commit("base")

    code, out, err = complexity

    assert_equal 0, code, err
    assert_match(/nothing is compared/, out)
    assert_match(/no default branch found/, out)
  end

  # An explicit base that names no commit is an error with or without the
  # flag: the caller named it, so a typo must not read as a clean run.
  # Contract: cli/L6
  def test_without_the_flag_a_missing_explicit_base_is_still_an_error
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("change")

    code, _, err = complexity("--base", "no-such-ref")

    assert_equal 2, code
    assert_match(/no-such-ref/, err)
  end

  # The dry check has no such flag: the option belongs to complexity alone.
  # Contract: cli/L6
  def test_dry_has_no_require_base_option
    init_repo

    code, _, err = exhale("dry", "--require-base")

    assert_equal 2, code
    assert_match(/invalid option: --require-base/, err)
  end

  # ---- explain -------------------------------------------------------------

  # explain resolves the base the same way a run does, so a flag that
  # would fail CI fails here too.
  # Contract: cli/L6
  def test_explain_validates_the_base_the_same_way
    init_repo
    git("checkout", "-q", "-b", "pr")
    commit("change")

    code, _, err = complexity("explain", "Order#total", "--base", "no-such-ref", "--require-base")
    assert_equal 2, code
    assert_match(/no-such-ref/, err)

    code, out, err = complexity("explain", "Order#total", "--base", "main", "--require-base")
    assert_equal 0, code, err
    assert_match(/Order#total/, out)
  end
end
