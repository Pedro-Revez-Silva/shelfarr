# frozen_string_literal: true

require "test_helper"

class SearchTitleVariantServiceTest < ActiveSupport::TestCase
  test "returns localized original and full combined title variants" do
    assert_equal(
      [ "La Nena", "The Girl", "La Nena / The Girl" ],
      SearchTitleVariantService.call(" La Nena / The Girl ")
    )
  end

  test "preserves ordinary and unspaced slash titles" do
    assert_equal [ "The Girl" ], SearchTitleVariantService.call("The Girl")
    assert_equal [ "AC/DC" ], SearchTitleVariantService.call("AC/DC")
  end

  test "returns no variants for a blank title" do
    assert_empty SearchTitleVariantService.call(nil)
    assert_empty SearchTitleVariantService.call("  ")
  end
end
