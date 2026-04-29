from django import forms
from django.contrib.auth.forms import UserCreationForm
from django.contrib.auth.models import User

from .models import (
    Transaction, Category, Budget, Household, RecurringTransaction,
    CategoryRule, Asset, Liability, MoneyRequest, Currency,
)


class BootstrapMixin:
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        for field_name, field in self.fields.items():
            existing = field.widget.attrs.get('class', '')
            if isinstance(field.widget, forms.CheckboxInput):
                field.widget.attrs['class'] = (existing + ' form-check-input').strip()
            elif isinstance(field.widget, (forms.Select, forms.SelectMultiple)):
                field.widget.attrs['class'] = (existing + ' form-select').strip()
            elif isinstance(field.widget, forms.Textarea):
                field.widget.attrs['class'] = (existing + ' form-control').strip()
                field.widget.attrs.setdefault('rows', 3)
            else:
                field.widget.attrs['class'] = (existing + ' form-control').strip()


class SignUpForm(BootstrapMixin, UserCreationForm):
    email = forms.EmailField(required=True)

    class Meta:
        model = User
        fields = ('username', 'email', 'password1', 'password2')


class HouseholdForm(BootstrapMixin, forms.ModelForm):
    partner_username = forms.CharField(
        required=False,
        help_text="Optional: username of your partner (must already have an account)."
    )

    class Meta:
        model = Household
        fields = ('name', 'base_currency')


class TransactionForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Transaction
        fields = ('transaction_type', 'category', 'amount', 'currency',
                  'payee', 'description', 'date')
        widgets = {
            'date': forms.DateInput(attrs={'type': 'date'}),
            'description': forms.TextInput(attrs={'placeholder': 'Optional notes'}),
            'payee': forms.TextInput(attrs={'placeholder': 'e.g. TotalEnergies, Shoprite'}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            self.fields['category'].queryset = Category.objects.filter(household=household)
            if household.base_currency:
                self.fields['currency'].initial = household.base_currency


class CategoryForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Category
        fields = ('name', 'category_type', 'color', 'icon')
        widgets = {
            'color': forms.TextInput(attrs={'type': 'color'}),
            'icon': forms.TextInput(attrs={'placeholder': 'bi-tag'}),
        }


class BudgetForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Budget
        fields = ('category', 'monthly_limit', 'month')
        widgets = {'month': forms.DateInput(attrs={'type': 'date'})}

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            self.fields['category'].queryset = Category.objects.filter(
                household=household, category_type=Category.EXPENSE
            )


class RecurringTransactionForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = RecurringTransaction
        fields = ('name', 'transaction_type', 'category', 'amount', 'currency',
                  'payee', 'frequency', 'start_date', 'next_due_date', 'end_date',
                  'auto_create', 'is_active', 'notes')
        widgets = {
            'start_date': forms.DateInput(attrs={'type': 'date'}),
            'next_due_date': forms.DateInput(attrs={'type': 'date'}),
            'end_date': forms.DateInput(attrs={'type': 'date'}),
            'notes': forms.Textarea(),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            self.fields['category'].queryset = Category.objects.filter(household=household)
            if household.base_currency:
                self.fields['currency'].initial = household.base_currency


class CategoryRuleForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = CategoryRule
        fields = ('pattern', 'match_type', 'case_sensitive', 'category', 'priority', 'is_active')
        widgets = {
            'pattern': forms.TextInput(attrs={'placeholder': 'e.g. TotalEnergies'}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            self.fields['category'].queryset = Category.objects.filter(household=household)


class AssetForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Asset
        fields = ('name', 'asset_type', 'value', 'currency', 'notes')
        widgets = {'notes': forms.Textarea()}


class LiabilityForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Liability
        fields = ('name', 'liability_type', 'balance', 'currency', 'interest_rate', 'notes')
        widgets = {'notes': forms.Textarea()}


class MoneyRequestForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = MoneyRequest
        fields = ('approver', 'amount', 'currency', 'purpose', 'category', 'notes')
        widgets = {
            'purpose': forms.TextInput(attrs={'placeholder': 'What is this money for?'}),
            'notes': forms.Textarea(),
        }

    def __init__(self, *args, household=None, requester=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            qs = household.members.all()
            if requester:
                qs = qs.exclude(pk=requester.pk)
            self.fields['approver'].queryset = qs
            self.fields['category'].queryset = Category.objects.filter(
                household=household, category_type=Category.EXPENSE
            )
            if household.base_currency:
                self.fields['currency'].initial = household.base_currency


class MoneyRequestResponseForm(BootstrapMixin, forms.Form):
    response_note = forms.CharField(
        required=False, widget=forms.Textarea(attrs={'rows': 2}),
        label='Note (optional)'
    )


class CSVImportForm(BootstrapMixin, forms.Form):
    file = forms.FileField(
        help_text='CSV with columns: date, type, amount, category, description, payee'
    )


class CurrencyForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Currency
        fields = ('code', 'name', 'symbol')


class ExchangeRateForm(BootstrapMixin, forms.Form):
    from_currency = forms.ModelChoiceField(queryset=Currency.objects.all())
    to_currency = forms.ModelChoiceField(queryset=Currency.objects.all())
    rate = forms.DecimalField(max_digits=18, decimal_places=6)
