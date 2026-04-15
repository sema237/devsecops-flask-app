from flask import jsonify
from werkzeug.exceptions import HTTPException


def register_error_handlers(app):
    @app.errorhandler(HTTPException)
    def handle_http_error(exc):
        return jsonify({
            'error': exc.name,
            'message': exc.description,
        }), exc.code


    @app.errorhandler(Exception)
    def handle_unexpected_error(exc):
        # SECURITY: Never expose stack traces in production
        app.logger.exception('Unhandled exception', exc_info=exc)
        return jsonify({
            'error': 'Internal Server Error',
            'message': 'An unexpected error occurred.',
        }), 500
