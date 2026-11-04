class AccountsController < ActionController::Base
  layout 'application'

  def index
    @heading = 'Fixture accounts'
  end
end
