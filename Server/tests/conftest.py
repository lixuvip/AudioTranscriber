import os

# Set a dummy token during test collection to prevent app initialization from crashing.
os.environ["VOICESCRIBE_TOKEN"] = "test-session-dummy-token"
