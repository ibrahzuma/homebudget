from django.contrib import admin
from .models import (
    Household, Category, Transaction, Budget, RecurringTransaction,
    CategoryRule, Alert, MoneyRequest, Asset, Liability, LiabilityPayment,
    NetWorthSnapshot, Currency, ExchangeRate, Meeting, AgreementItem,
    Goal, GoalContribution, Project, Receivable, ReceivablePayment,
    ChatMessage, ChatReadState,
)

for m in [Household, Category, Transaction, Budget, RecurringTransaction,
          CategoryRule, Alert, MoneyRequest, Asset, Liability, LiabilityPayment,
          NetWorthSnapshot, Currency, ExchangeRate, Meeting, AgreementItem,
          Goal, GoalContribution, Project, Receivable, ReceivablePayment,
          ChatMessage, ChatReadState]:
    admin.site.register(m)
