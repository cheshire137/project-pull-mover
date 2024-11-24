require "test_helper"

class ProjectPullMover::UtilsTest < Minitest::Test
  def test_replace_hyphens
    assert_equal("FooBar", ProjectPullMover::Utils.replace_hyphens("foo-bar"))
  end
end
