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

    # Debts (Liabilities + payments)
    path('debts/', views.debt_list, name='debt_list'),
    path('debts/new/', views.liability_create, name='liability_create'),
    path('debts/<int:pk>/', views.debt_detail, name='debt_detail'),
    path('debts/<int:pk>/edit/', views.liability_edit, name='liability_edit'),
    path('debts/<int:pk>/delete/', views.liability_delete, name='liability_delete'),
    path('debts/<int:pk>/payments/new/', views.payment_create, name='payment_create'),
    path('debts/<int:pk>/payments/<int:payment_pk>/delete/',
         views.payment_delete, name='payment_delete'),

    # Currencies
    path('currencies/', views.currency_list, name='currency_list'),
    path('currencies/new/', views.currency_create, name='currency_create'),
    path('currencies/rates/new/', views.rate_create, name='rate_create'),

    # Import / Export
    path('export/csv/', views.export_csv, name='export_csv'),
    path('import/csv/', views.import_csv, name='import_csv'),

    # Forecast
    path('forecast/', views.forecast_view, name='forecast'),

    # Monthly report
    path('reports/', views.monthly_report, name='monthly_report'),
    path('reports/<int:year>/<int:month>/csv/', views.monthly_report_csv, name='monthly_report_csv'),

    # Receivables — people who borrowed from us
    path('lent/', views.receivable_list, name='receivable_list'),
    path('lent/new/', views.receivable_create, name='receivable_create'),
    path('lent/<int:pk>/', views.receivable_detail, name='receivable_detail'),
    path('lent/<int:pk>/edit/', views.receivable_edit, name='receivable_edit'),
    path('lent/<int:pk>/delete/', views.receivable_delete, name='receivable_delete'),
    path('lent/<int:pk>/repayments/new/', views.receivable_payment_create, name='receivable_payment_create'),
    path('lent/<int:pk>/repayments/<int:payment_pk>/delete/',
         views.receivable_payment_delete, name='receivable_payment_delete'),

    # Savings goals
    path('goals/', views.goal_list, name='goal_list'),
    path('goals/new/', views.goal_create, name='goal_create'),
    path('goals/<int:pk>/', views.goal_detail, name='goal_detail'),
    path('goals/<int:pk>/edit/', views.goal_edit, name='goal_edit'),
    path('goals/<int:pk>/delete/', views.goal_delete, name='goal_delete'),
    path('goals/<int:pk>/contribute/', views.goal_contribute, name='goal_contribute'),
    path('goals/<int:pk>/contributions/<int:contrib_pk>/delete/',
         views.goal_contribution_delete, name='goal_contribution_delete'),

    # Projects
    path('projects/', views.project_list, name='project_list'),
    path('projects/new/', views.project_create, name='project_create'),
    path('projects/<int:pk>/', views.project_detail, name='project_detail'),
    path('projects/<int:pk>/edit/', views.project_edit, name='project_edit'),
    path('projects/<int:pk>/delete/', views.project_delete, name='project_delete'),

    # Household chat
    path('chat/', views.chat_view, name='chat'),
    path('chat/send/', views.chat_send, name='chat_send'),
    path('chat/recent/', views.chat_recent, name='chat_recent'),

    # Meetings & agreements
    path('meetings/', views.meeting_list, name='meeting_list'),
    path('meetings/new/', views.meeting_create, name='meeting_create'),
    path('meetings/<int:pk>/', views.meeting_detail, name='meeting_detail'),
    path('meetings/<int:pk>/edit/', views.meeting_edit, name='meeting_edit'),
    path('meetings/<int:pk>/delete/', views.meeting_delete, name='meeting_delete'),
    path('meetings/<int:pk>/items/new/', views.agreement_create, name='agreement_create'),
    path('meetings/<int:pk>/items/<int:item_pk>/edit/', views.agreement_edit, name='agreement_edit'),
    path('meetings/<int:pk>/items/<int:item_pk>/delete/', views.agreement_delete, name='agreement_delete'),
    path('meetings/<int:pk>/items/<int:item_pk>/quick/', views.agreement_quick_update, name='agreement_quick_update'),
]
