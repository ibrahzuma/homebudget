"""Django settings for budget_project."""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _env_list(name, default=''):
    """Comma-separated env var -> list of stripped, non-empty strings."""
    return [v.strip() for v in os.environ.get(name, default).split(',') if v.strip()]


# Dev defaults are kept so `runserver` still works with no environment set up;
# production overrides every one of these via /opt/homebudget/.env (see README).
SECRET_KEY = os.environ.get(
    'DJANGO_SECRET_KEY',
    'django-insecure-change-this-in-production-please-use-env-vars',
)
DEBUG = os.environ.get('DJANGO_DEBUG', 'True').lower() not in ('0', 'false', 'no')
ALLOWED_HOSTS = _env_list('DJANGO_ALLOWED_HOSTS') or ['*']
CSRF_TRUSTED_ORIGINS = _env_list('DJANGO_CSRF_TRUSTED_ORIGINS')

INSTALLED_APPS = [
    'daphne',                       # must come first so its runserver wraps Django's
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'django.contrib.humanize',
    'channels',
    'rest_framework',
    'rest_framework.authtoken',
    'budget_app',
]

ASGI_APPLICATION = 'budget_project.asgi.application'

# InMemory only carries messages within a single process. Production sets
# REDIS_URL so chat/notifications still fan out if the app ever runs >1 worker.
_redis_url = os.environ.get('REDIS_URL')
if _redis_url:
    CHANNEL_LAYERS = {
        'default': {
            'BACKEND': 'channels_redis.core.RedisChannelLayer',
            'CONFIG': {'hosts': [_redis_url]},
        },
    }
else:
    CHANNEL_LAYERS = {
        'default': {
            'BACKEND': 'channels.layers.InMemoryChannelLayer',
        },
    }

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
    'budget_app.middleware.AutoApplyRecurringMiddleware',
]

ROOT_URLCONF = 'budget_project.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
                'budget_app.context_processors.household_context',
            ],
        },
    },
]

WSGI_APPLICATION = 'budget_project.wsgi.application'

def _database_from_url(url):
    """Parse postgres://user:pass@host:port/name into a Django DATABASES entry.

    Avoids a dj-database-url dependency; we only ever need the postgres case.
    """
    from urllib.parse import unquote, urlparse

    p = urlparse(url)
    if p.scheme not in ('postgres', 'postgresql'):
        raise ValueError(f'Unsupported DATABASE_URL scheme: {p.scheme!r}')
    return {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': unquote(p.path.lstrip('/')),
        'USER': unquote(p.username or ''),
        'PASSWORD': unquote(p.password or ''),
        'HOST': p.hostname or '127.0.0.1',
        'PORT': str(p.port or 5432),
        # Reuse connections for 10 min instead of reconnecting per request.
        'CONN_MAX_AGE': int(os.environ.get('DJANGO_CONN_MAX_AGE', '600')),
    }


_database_url = os.environ.get('DATABASE_URL')
if _database_url:
    DATABASES = {'default': _database_from_url(_database_url)}
else:
    DATABASES = {
        'default': {
            'ENGINE': 'django.db.backends.sqlite3',
            # Kept outside the code tree in production so redeploys never touch it.
            'NAME': os.environ.get('DJANGO_DB_PATH') or BASE_DIR / 'db.sqlite3',
        }
    }

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'Africa/Dar_es_Salaam'
USE_I18N = True
USE_TZ = True

STATIC_URL = 'static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'      # nginx serves this in production
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

if not DEBUG:
    # nginx terminates the connection and passes the real scheme through.
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
    SESSION_COOKIE_HTTPONLY = True
    CSRF_COOKIE_HTTPONLY = True             # JS reads the token from the rendered form field
    X_FRAME_OPTIONS = 'DENY'
    SECURE_CONTENT_TYPE_NOSNIFF = True
    SECURE_REFERRER_POLICY = 'same-origin'
    # Cookie Secure flags stay off while the site is reachable over plain HTTP
    # on a bare IP; turn these (and SECURE_SSL_REDIRECT) on once TLS is in front.
    SESSION_COOKIE_SECURE = os.environ.get('DJANGO_SECURE_COOKIES', '').lower() in ('1', 'true', 'yes')
    CSRF_COOKIE_SECURE = SESSION_COOKIE_SECURE

# Mobile JSON API (/api/v1/). Token auth only — no session auth, so the API
# never depends on cookies or CSRF.
REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.TokenAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_RENDERER_CLASSES': ['rest_framework.renderers.JSONRenderer'],
    'DEFAULT_PARSER_CLASSES': [
        'rest_framework.parsers.JSONParser',
        'rest_framework.parsers.MultiPartParser',
    ],
    'DEFAULT_THROTTLE_CLASSES': ['rest_framework.throttling.ScopedRateThrottle'],
    # Brute-force guard on login/signup, per client IP
    'DEFAULT_THROTTLE_RATES': {'auth': os.environ.get('API_AUTH_THROTTLE', '10/min')},
    # nginx is the only proxy in front of daphne
    'NUM_PROXIES': 1 if not DEBUG else None,
}

LOGIN_URL = 'login'
LOGIN_REDIRECT_URL = 'dashboard'
LOGOUT_REDIRECT_URL = 'login'
