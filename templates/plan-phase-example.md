# Plan Phase Example — Worked Reference

This is the canonical worked example referenced by the "Phased Plan" section of
[`AGENTS.md`](../AGENTS.md). It shows the required level of plan precision:
phase header, objective, inputs, outputs, files touched, a full edit manifest
with before/after snippets, and a validation gate.

```
Phase 3: Implement JWT authentication middleware
Owner: rails-backend
Objective: Add middleware that validates JWT tokens and sets current_user_id.
Inputs: principal's auth contract (method signature + error shape) +
        cartographer's map (insert point at app/middleware/auth_middleware.rb:5).
Outputs:
  - New file: app/middleware/auth_middleware.rb
  - Modified: config/application.rb (register middleware)
  - New file: spec/middleware/auth_middleware_spec.rb

Files touched:
  - CREATE  app/middleware/auth_middleware.rb
  - INSERT  config/application.rb (after line 15)
  - CREATE  spec/middleware/auth_middleware_spec.rb

Edit manifest:

Edit #1: CREATE app/middleware/auth_middleware.rb
  Full content:
    class AuthMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        token = extract_bearer(env['HTTP_AUTHORIZATION'])
        payload = JwtVerifier.verify!(token)
        env['current_user_id'] = payload['sub']
        @app.call(env)
      rescue JwtVerifier::InvalidToken => e
        [401, { 'Content-Type' => 'application/json' },
         [{ error: 'invalid_token', message: e.message }.to_json]]
      end

      private

      def extract_bearer(header)
        return nil unless header&.start_with?('Bearer ')
        header.sub('Bearer ', '')
      end
    end

Edit #2: INSERT config/application.rb (blank line + middleware after line 15)
  Before (lines 13-15):
    config.load_defaults 7.1

    config.api_only = true
  After (lines 13-17):
    config.load_defaults 7.1

    config.api_only = true

    config.middleware.insert_before Rack::Runtime, AuthMiddleware

Edit #3: CREATE spec/middleware/auth_middleware_spec.rb
  Full content:
    require 'spec_helper'

    RSpec.describe AuthMiddleware do
      # Happy path: valid token sets current_user_id
      # Expired token: returns 401 with error body
      # Missing token: returns 401 with error body
      # Malformed header: returns 401 with error body
    end

Validation gate: `bundle exec rspec spec/middleware/auth_middleware_spec.rb` passes;
  lead reviews the diff before Phase 4 begins.
```

Note the Edit #2 Before/After: the *After* block shows the newly inserted
`config.middleware.insert_before` line — the before/after difference is the
insertion itself.