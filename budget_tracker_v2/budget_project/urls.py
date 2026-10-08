"""URL Configuration for budget_project."""
from django.conf import settings
from django.contrib import admin
from django.contrib.staticfiles.urls import staticfiles_urlpatterns
from django.urls import path, include
from django.contrib.auth import views as auth_views

from budget_app import views as budget_views

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/v1/', include('budget_app.api.urls')),   # mobile app
    path('login/', budget_views.AppLoginView.as_view(), name='login'),
    path('logout/', auth_views.LogoutView.as_view(), name='logout'),
    path('', include('budget_app.urls')),
]

if settings.DEBUG:
    urlpatterns += staticfiles_urlpatterns()
