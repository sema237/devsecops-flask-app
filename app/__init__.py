import logging
from flask import Flask, request, g
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from app.routes import api_bp
from app.errors import register_error_handlers
import uuid

db = SQLAlchemy()
migrate = Migrate()

logging.basicConfig(
    format='{"time":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}',
    level=logging.INFO,
)
logger = logging.getLogger(__name__)


def create_app(config_name='development'):
    app = Flask(__name__)
    app.config.from_object(f'app.config.{config_name.title()}Config')

    db.init_app(app)
    migrate.init_app(app, db)

    app.register_blueprint(api_bp, url_prefix='/api/v1')

    register_error_handlers(app)

    @app.before_request
    def add_request_id():
        g.request_id = request.headers.get('X-Request-ID', str(uuid.uuid4()))

    @app.after_request
    def set_security_headers(response):
        response.headers['X-Request-ID'] = g.get('request_id', '')
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['X-Frame-Options'] = 'DENY'
        response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
        return response

    return app
