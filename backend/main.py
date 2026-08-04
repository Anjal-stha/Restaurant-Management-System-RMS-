import os
from fastapi import FastAPI
from dotenv import load_dotenv

# Load environment variables from .env
load_dotenv()

app = FastAPI(
    title="The Everest Bistro API",
    version="1.0.0",
    description="Backend API for menu ordering and POS system"
)

@app.get("/")
def read_root():
    return {
        "status": "online",
        "message": "Welcome to The Everest Bistro API"
    }

@app.get("/health")
def health_check():
    # Quick check to ensure environment variables are being read
    supabase_url_exists = bool(os.getenv("SUPABASE_URL"))
    return {
        "status": "healthy",
        "environment_loaded": supabase_url_exists
    }