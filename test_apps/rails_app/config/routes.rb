Rails.application.routes.draw do
  get '/accounts', to: 'accounts#index'
  get '/users', to: 'users#index'
end
