Rails.application.routes.draw do
  resource :session, only: %i[ new destroy ]
  resource :account, only: :destroy
  get "auth/github/callback", to: "sessions#create", as: :github_callback
  get "auth/failure", to: "sessions#failure"

  root to: redirect("/repositories", status: 302)

  resources :repositories, only: :index

  # GitHub repositories are addressed by owner/name, e.g. /repositories/rails/rails/pull_requests
  scope "repositories/:owner/:repo", as: :repository, constraints: { owner: %r{[^/]+}, repo: %r{[^/]+} } do
    resource :pin, only: %i[ create destroy ]
    resources :pull_requests, only: :index, param: :number do
      resources :assessments, only: :create
    end
  end

  resources :assessments, only: %i[ index show ]
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
