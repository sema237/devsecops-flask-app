from flask import Blueprint, request, jsonify, current_app, g
from sqlalchemy.exc import IntegrityError
from app import db
from app.models import User
from marshmallow import Schema, fields, validate, ValidationError


api_bp = Blueprint('api', __name__)


class UserSchema(Schema):
    username = fields.Str(required=True, validate=validate.Length(min=3, max=80))
    email = fields.Email(required=True)
    password = fields.Str(required=True, validate=validate.Length(min=12))  # SECURITY: Min 12 chars


@api_bp.route('/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'healthy'}), 200


@api_bp.route('/users', methods=['POST'])
def create_user():
    schema = UserSchema()
    try:
        data = schema.load(request.get_json(silent=True) or {})
    except ValidationError as exc:
        return jsonify({'errors': exc.messages}), 400

    user = User(username=data['username'], email=data['email'])
    user.set_password(data['password'])
    db.session.add(user)
    try:
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        return jsonify({'error': 'Email or username already registered'}), 409

    current_app.logger.info(
        'User created',
        extra={'request_id': g.get('request_id'), 'username': data['username']},
    )
    return jsonify(user.to_dict()), 201
