# Defines a throwaway top-level `Current` (ActiveSupport::CurrentAttributes)
# with the given attributes.
#
# CurrentAttributes caches its instance under the class NAME, so every stubbed
# `Current` shares one slot; without clearing it an example would inherit the
# instance (and the attribute set) of whichever stub ran first.
module CurrentStub
  def stub_current(*attributes)
    ActiveSupport::CurrentAttributes.clear_all
    stub_const("Current", Class.new(ActiveSupport::CurrentAttributes) { attribute(*attributes) })
  end
end

RSpec.configure do |config|
  config.include CurrentStub
  config.after { ActiveSupport::CurrentAttributes.clear_all }
end
