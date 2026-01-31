# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

puts "Seeding default settings..."
SettingsService.seed_defaults!
puts "Created #{Setting.count} settings"

if Rails.env.development?
  puts "Creating development admin user..."

  unless User.exists?(username: "admin")
    User.create!(
      name: "Admin",
      username: "admin",
      password: "Password1234",
      password_confirmation: "Password1234"
    )
    puts "Created admin user: admin / Password1234"
  end
end

puts "Seeding complete!"
