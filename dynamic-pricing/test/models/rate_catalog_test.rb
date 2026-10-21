require "test_helper"

class RateCatalogTest < ActiveSupport::TestCase
  # 36 unique combinations, so the refresh batch never misses or repeats a key.
  test "lists every combination exactly once" do
    assert_equal 36, RateCatalog::ALL_ATTRIBUTES.size
    assert_equal RateCatalog::ALL_ATTRIBUTES, RateCatalog::ALL_ATTRIBUTES.uniq
    assert_includes RateCatalog::ALL_ATTRIBUTES,
                    { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
  end
end
