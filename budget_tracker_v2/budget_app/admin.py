from django.contrib import admin
from .models import (
    Household, Category, Transaction, Budget, RecurringTransaction,
    CategoryRule, Alert, MoneyRequest, Asset, Liability, LiabilityPayment,
    NetWorthSnapshot, Currency, ExchangeRate, Meeting, AgreementItem,
    Goal, GoalContribution, Project, Receivable, ReceivablePayment,
)

for m in [Household, Category, Transaction, Budget, RecurringTransaction,
          CategoryRule, Alert, MoneyRequest, Asset, Liability, LiabilityPayment,
          NetWorthSnapshot, Currency, ExchangeRate, Meeting, AgreementItem,
          Goal, GoalContribution, Project, Receivable, ReceivablePayment]:
    admin.site.register(m)
