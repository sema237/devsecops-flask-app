import os
from datetime import timedelta


class BaseConfig:
    SECRET_KEY = os.environ.get('SECRET_KEY', 'change-me-in-production')
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    MAX_CONTENT_LENGTH = 16 * 1024 * 1024  # 16 MB upload limit
    PERMANENT_SESSION_LIFETIME = timedelta(hours=1)
    # SECURITY: Always parameterize queries via SQLAlchemy
    # Never use raw string formatting in SQL


class DevelopmentConfig(BaseConfig):
    DEBUG = True
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        'DATABASE_URL', 'sqlite:///dev.db')


class TestingConfig(BaseConfig):
    TESTING = True
    WTF_CSRF_ENABLED = False
    SQLALCHEMY_DATABASE_URI = 'sqlite:///:memory:'


class ProductionConfig(BaseConfig):
    DEBUG = False
    SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL')
    # SECURITY: Enforce HTTPS in production
    SESSION_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = 'Lax'
    PREFERRED_URL_SCHEME = 'https'

    def __init__(self):
        db_url = os.environ.get('DATABASE_URL')
        assert db_url, "DATABASE_URL environment variable must be set in production"
        assert os.environ.get('SECRET_KEY'), "SECRET_KEY environment variable must be set in production"
