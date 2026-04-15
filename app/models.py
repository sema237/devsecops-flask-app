from app import db
from datetime import datetime, timezone
from werkzeug.security import generate_password_hash, check_password_hash


class User(db.Model):
    __tablename__ = 'users'
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False, index=True)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(256), nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
    password_changed_at = db.Column(db.DateTime)
    is_active = db.Column(db.Boolean, default=True)

    def __repr__(self):
        return f"<User id={self.id} username={self.username!r}>"

    def set_password(self, password):
        # SECURITY: Werkzeug uses scrypt by default (strong)
        self.password_hash = generate_password_hash(password)
        self.password_changed_at = datetime.now(timezone.utc)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    def to_dict(self):
        return {
            'id': self.id,
            'username': self.username,
            'email': self.email,
            'created_at': self.created_at.isoformat(),
            # SECURITY: Never expose password_hash
        }
