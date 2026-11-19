// ToastMate settings. Paste the two values from Supabase → Project Settings → API.
// The anon key is meant to be public: the database rules (supabase/schema.sql) decide who can see what.
// Leave both empty to keep data in this browser only.
window.TOASTMATE_CONFIG = {
  supabaseUrl: 'https://tbpsjebcpbntcrjkmxbk.supabase.co',
  // Accounts that see example-data previews (Supabase user id, not secret).
  ownerIds: ['4ba309c9-4c86-4d7a-94c5-a6db7e34bd8a'],
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRicHNqZWJjcGJudGNyamtteGJrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTUwMDY2OTcsImV4cCI6MjExMDU4MjY5N30.0wviDGN_NnSEi5z1dZkOaeCXvgtIQAOZpI6RbApRSKQ',  // starts with eyJ...
};
