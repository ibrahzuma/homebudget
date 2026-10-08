"""URLs for the mobile JSON API, mounted at /api/v1/ (see budget_project/urls.py)."""
from django.urls import path

from . import views as v

urlpatterns = [
    # Auth
    path('auth/login/', v.LoginView.as_view()),
    path('auth/signup/', v.SignupView.as_view()),
    path('auth/logout/', v.LogoutView.as_view()),

    # Push notifications (FCM registration tokens)
    path('devices/', v.DeviceRegisterView.as_view()),
    path('devices/unregister/', v.DeviceUnregisterView.as_view()),

    # Session context
    path('me/', v.MeView.as_view()),
    path('meta/', v.MetaView.as_view()),

    # Household
    path('household/', v.HouseholdView.as_view()),
    path('household/join/', v.HouseholdJoinView.as_view()),
    path('household/members/', v.HouseholdMembersView.as_view()),
    path('household/members/<int:user_id>/', v.HouseholdMemberDetailView.as_view()),
    path('household/invites/', v.InvitesView.as_view()),
    path('household/invites/<int:pk>/revoke/', v.InviteRevokeView.as_view()),

    path('dashboard/', v.DashboardView.as_view()),

    # Transactions
    path('transactions/', v.TransactionListView.as_view()),
    path('transactions/export/', v.TransactionExportView.as_view()),
    path('transactions/import/', v.TransactionImportView.as_view()),
    path('transactions/<int:pk>/', v.TransactionDetailView.as_view()),

    path('categories/', v.CategoryListView.as_view()),
    path('categories/<int:pk>/', v.CategoryDetailView.as_view()),

    path('budgets/', v.BudgetListView.as_view()),
    path('budgets/<int:pk>/', v.BudgetDetailView.as_view()),

    path('recurring/', v.RecurringListView.as_view()),
    path('recurring/run-now/', v.RecurringRunNowView.as_view()),
    path('recurring/<int:pk>/', v.RecurringDetailView.as_view()),

    path('calendar/', v.CalendarView.as_view()),
    path('forecast/', v.ForecastView.as_view()),

    path('rules/', v.RuleListView.as_view()),
    path('rules/apply/', v.RulesApplyView.as_view()),
    path('rules/<int:pk>/', v.RuleDetailView.as_view()),

    path('alerts/', v.AlertListView.as_view()),
    path('alerts/read-all/', v.AlertReadAllView.as_view()),
    path('alerts/<int:pk>/read/', v.AlertReadView.as_view()),

    # Money requests
    path('requests/', v.MoneyRequestListView.as_view()),
    path('requests/<int:pk>/', v.MoneyRequestDetailView.as_view()),
    path('requests/<int:pk>/approve/', v.MoneyRequestActionView.as_view(action='approve')),
    path('requests/<int:pk>/reject/', v.MoneyRequestActionView.as_view(action='reject')),
    path('requests/<int:pk>/cancel/', v.MoneyRequestActionView.as_view(action='cancel')),

    # Net worth
    path('networth/', v.NetWorthView.as_view()),
    path('networth/snapshot/', v.NetWorthSnapshotView.as_view()),
    path('assets/', v.AssetListView.as_view()),
    path('assets/<int:pk>/', v.AssetDetailView.as_view()),

    path('debts/', v.DebtListView.as_view()),
    path('debts/<int:pk>/', v.DebtDetailView.as_view()),
    path('debts/<int:pk>/payments/', v.DebtPaymentCreateView.as_view()),
    path('debts/<int:pk>/payments/<int:payment_pk>/', v.DebtPaymentDeleteView.as_view()),

    path('lent/', v.LentListView.as_view()),
    path('lent/<int:pk>/', v.LentDetailView.as_view()),
    path('lent/<int:pk>/repayments/', v.LentPaymentCreateView.as_view()),
    path('lent/<int:pk>/repayments/<int:payment_pk>/', v.LentPaymentDeleteView.as_view()),

    path('goals/', v.GoalListView.as_view()),
    path('goals/<int:pk>/', v.GoalDetailView.as_view()),
    path('goals/<int:pk>/contributions/', v.GoalContributionCreateView.as_view()),
    path('goals/<int:pk>/contributions/<int:contrib_pk>/', v.GoalContributionDeleteView.as_view()),

    path('projects/', v.ProjectListView.as_view()),
    path('projects/<int:pk>/', v.ProjectDetailView.as_view()),

    path('currencies/', v.CurrencyListView.as_view()),
    path('currencies/rates/', v.ExchangeRateCreateView.as_view()),

    path('reports/monthly/', v.MonthlyReportView.as_view()),
    path('reports/monthly/<int:year>/<int:month>/csv/', v.MonthlyReportCSVView.as_view()),

    # Contribution groups: vikoba (savings & loans) and mchezo (rotating pot)
    path('groups/', v.ContributionGroupListView.as_view()),
    path('groups/<int:pk>/', v.ContributionGroupDetailView.as_view()),
    path('groups/<int:pk>/contribute/', v.GroupContributeView.as_view()),
    path('groups/<int:pk>/payouts/', v.GroupPayoutCreateView.as_view()),
    path('groups/<int:pk>/loans/', v.GroupLoanCreateView.as_view()),
    path('groups/<int:pk>/members/', v.GroupMemberListView.as_view()),
    path('groups/<int:pk>/members/<int:member_pk>/', v.GroupMemberDetailView.as_view()),

    path('chat/', v.ChatView.as_view()),
    path('chat/read/', v.ChatReadView.as_view()),

    path('meetings/', v.MeetingListView.as_view()),
    path('meetings/<int:pk>/', v.MeetingDetailView.as_view()),
    path('meetings/<int:pk>/items/', v.AgreementCreateView.as_view()),
    path('meetings/<int:pk>/items/<int:item_pk>/', v.AgreementDetailView.as_view()),
    path('meetings/<int:pk>/items/<int:item_pk>/quick/', v.AgreementQuickUpdateView.as_view()),
]
