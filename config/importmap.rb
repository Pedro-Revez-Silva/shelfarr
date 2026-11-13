pin "application"
pin "consumer_reader_engine", to: "consumer_reader_engine.js", preload: false
pin "consumer_progress_sync", preload: false
pin "consumer_offline", preload: false
pin "consumer_page_reader", preload: false
pin "consumer_read_along", preload: false
pin "consumer_pdf_engine", to: "consumer_pdf_engine.js", preload: false
pin "settings_navigation_guard"
pin "web_app_install"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "@rails/actioncable/src", to: "actioncable.esm.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
