from django.contrib import admin
from .models import (
    Household, Category, Transaction, Budget, RecurringTransaction,
    CategoryRule, Alert, MoneyRequest, Asset, Liability, NetWorthSnapshot,
    Currency, ExchangeRate,
)

for m in [Household, Category, Transaction, Budget, RecurringTransaction,
          CategoryRule, Alert, MoneyRequest, Asset, Liability,
          NetWorthSnapshot, Currency, ExchangeRate]:
    admin.site.register(m)
