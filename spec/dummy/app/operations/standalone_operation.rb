# Enumeration shape 2: a leaf that includes the contract DIRECTLY, with no
# shared base at all (sidekick-web's ~100 operations look like this). It is
# registered by the `included` hook rather than by `inherited`, and both shapes
# land in the same registry, so one meta-spec covers a codebase that mixes them.
class StandaloneOperation
  include StandardAudit::Operation

  audits "user.updated"

  def initialize(user)
    @user = user
  end

  def execute
    audit!("user.updated", target: @user)
  end
end
