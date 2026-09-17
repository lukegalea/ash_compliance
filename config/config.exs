# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

# Ash needs to know how to count string length. Codepoints is the
# recommended setting and matches how SQL data layers count.
config :ash, :default_string_length_count, :codepoints

if Mix.env() == :test do
  import_config "test.exs"
end
