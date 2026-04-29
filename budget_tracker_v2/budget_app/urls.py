from django.urls import path
from . import views

urlpatterns = [
    path('', views.dashboard, name='dashboard'),
    path('signup/', views.signup_view, name='signup'),

    # Household
    path('household/setup/', views.household_setup, name='household_setup'),
    path('household/settings/', views.household_settings, name='household_settings'),

    # Transactions
    path('transactions/', views.transaction_list, name='transaction_list'),
    path('transactions/new/', views.transaction_create, name='transaction_create'),
    path('transactions/<int:pk>/edit/', views.transaction_edit, name='transaction_edit'),
    path('transactions/<int:pk>/delete/', views.transaction_delete, name='transaction_delete'),

    # Categories
    path('categories/', views.category_list, name='category_list'),
    path('categories/new/', views.category_create, name='category_create'),
    path('categories/<int:pk>/delete/', views.category_delete, name='category_delete'),

    # Budgets
    path('budgets/', views.budget_list, name='budget_list'),
    path('budgets/new/', views.budget_create, name='budget_create'),
    path('budgets/<int:pk>/delete/', views.budget_delete, name='budget_delete'),

    # Recurring
    path('recurring/', views.recurring_list, name='recurring_list'),
    path('recurring/new/', views.recurring_create, name='recurring_create'),
    path('recurring/<int:pk>/edit/', views.recurring_edit, name='recurring_edit'),
    path('recurring/<int:pk>/delete/', views.recurring_delete, name='recurring_delete'),
    path('recurring/run-now/', views.recurring_run_now, name='recurring_run_now'),

    # Calendar
    path('calendar/', views.bill_calendar, name='bill_calendar'),

    # Rules
    path('rules/', views.rule_list, name='rule_list'),
    path('rules/new/', views.rule_create, name='rule_create'),
    path('rules/<int:pk>/delete/', views.rule_delete, name='rule_delete'),
    path('rules/apply/', views.rules_apply_existing, name='rules_apply_existing'),

    # Alerts
    path('alerts/', views.alert_list, name='alert_list'),
    path('alerts/<int:pk>/read/', views.alert_mark_read, name='alert_mark_read'),
    path('alerts/read-all/', views.alert_mark_all_read, name='alert_mark_all_read'),

    # Money Requests
    path('requests/', views.request_list, name='request_list'),
    path('requests/new/', views.request_create, name='request_create'),
    path('requests/<int:pk>/', views.request_detail, name='request_detail'),

    # Net worth
    path('networth/', views.networth_view, name='networth'),
    path('networth/snapshot/', views.networth_snapshot, name='networth_snapshot'),
    path('assets/new/', views.asset_create, name='asset_create'),
    path('assets/<int:pk>/edit/', views.asset_edit, name='asset_edit'),
    path('assets/<int:pk>/delete/', views.asset_delete, name='asset_delete'),
    path('liabilities/new/', views.liability_create, name='liability_create'),
    path('liabilities/<int:pk>/edit/', views.liability_edit, name='liability_edit'),
    path('liabilities/<int:pk>/delete/', views.liability_delete, name='liability_delete'),

    # Currencies
    path('currencies/', views.currency_list, name='currency_list'),
    path('currencies/new/', views.currency_create, name='currency_create'),
    path('currencies/rates/new/', views.rate_create, name='rate_create'),

    # Import / Export
    path('export/csv/', views.export_csv, name='export_csv'),
    path('import/csv/', views.import_csv, name='import_csv'),

    # Forecast
    path('forecast/', views.forecast_view, name='forecast'),
]
