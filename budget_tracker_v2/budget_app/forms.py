from django import forms
from django.contrib.auth.forms import UserCreationForm
from django.contrib.auth.models import User

from .models import (
    Transaction, Category, Budget, Household, RecurringTransaction,
    CategoryRule, Asset, Liability, LiabilityPayment, MoneyRequest, Currency,
    Meeting, AgreementItem, Goal, GoalContribution, Project,
    Receivable, ReceivablePayment,
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
                  'payee', 'description', 'date', 'project')
        widgets = {
            'date': forms.DateInput(attrs={'type': 'date'}),
            'description': forms.TextInput(attrs={'placeholder': 'Optional notes'}),
            'payee': forms.TextInput(attrs={'placeholder': 'e.g. TotalEnergies, Shoprite'}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            self.fields['category'].queryset = Category.objects.filter(household=household)
            self.fields['project'].queryset = Project.objects.filter(
                household=household
            ).exclude(status__in=[Project.STATUS_COMPLETED, Project.STATUS_CANCELLED])
            self.fields['project'].required = False
            self.fields['project'].empty_label = '— None —'
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
        fields = ('name', 'asset_type', 'value', 'currency',
                  'acquisition_date', 'location', 'size', 'registration_number',
                  'notes')
        widgets = {
            'notes': forms.Textarea(),
            'acquisition_date': forms.DateInput(attrs={'type': 'date'}),
            'location': forms.TextInput(attrs={'placeholder': 'e.g. Plot 17, Mikocheni'}),
            'size': forms.TextInput(attrs={'placeholder': 'e.g. 120 m², 0.5 acre, 3 bed / 2 bath'}),
            'registration_number': forms.TextInput(attrs={'placeholder': 'Title deed / plate / license #'}),
        }


class LiabilityForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Liability
        fields = ('name', 'liability_type', 'lender', 'balance', 'original_amount',
                  'currency', 'interest_rate', 'start_date', 'due_date', 'notes')
        widgets = {
            'notes': forms.Textarea(),
            'start_date': forms.DateInput(attrs={'type': 'date'}),
            'due_date': forms.DateInput(attrs={'type': 'date'}),
            'lender': forms.TextInput(attrs={'placeholder': 'Bank, person, or institution'}),
        }


class LiabilityPaymentForm(BootstrapMixin, forms.ModelForm):
    record_as_expense = forms.BooleanField(
        required=False, initial=True,
        label='Also record this payment as a household expense',
    )
    expense_category = forms.ModelChoiceField(
        queryset=Category.objects.none(), required=False,
        label='Expense category (if recorded as expense)',
        help_text='Optional — leave blank to auto-create a "Debt Payment" category.'
    )

    class Meta:
        model = LiabilityPayment
        fields = ('date', 'amount', 'currency', 'notes')
        widgets = {
            'date': forms.DateInput(attrs={'type': 'date'}),
            'notes': forms.Textarea(attrs={'rows': 2}),
        }

    def __init__(self, *args, household=None, liability=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            self.fields['expense_category'].queryset = Category.objects.filter(
                household=household, category_type=Category.EXPENSE
            )
            if household.base_currency and not self.initial.get('currency'):
                self.fields['currency'].initial = household.base_currency
        if liability and not self.initial.get('currency'):
            self.fields['currency'].initial = liability.currency


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


class MeetingForm(BootstrapMixin, forms.ModelForm):
    carry_over_open_items = forms.BooleanField(
        required=False, initial=True,
        label='Carry over open action items from the previous meeting',
    )

    class Meta:
        model = Meeting
        fields = ('title', 'meeting_date', 'participants', 'agenda', 'minutes', 'status')
        widgets = {
            'meeting_date': forms.DateInput(attrs={'type': 'date'}),
            'participants': forms.CheckboxSelectMultiple(),
            'agenda': forms.Textarea(attrs={'rows': 3,
                'placeholder': 'Topics to cover, e.g. budget review, savings, upcoming expenses'}),
            'minutes': forms.Textarea(attrs={'rows': 5,
                'placeholder': 'What was discussed and decided'}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        self._previous_meeting = None
        if household:
            self.fields['participants'].queryset = household.members.all()
            if not self.instance.pk:
                self.fields['participants'].initial = household.members.all()
                self._previous_meeting = household.meetings.order_by('-meeting_date').first()
        # CheckboxSelectMultiple doesn't want the form-select class
        self.fields['participants'].widget.attrs.pop('class', None)
        # Only show the carry-over checkbox on create when a previous meeting exists
        if self.instance.pk or not self._previous_meeting:
            self.fields.pop('carry_over_open_items')


class AgreementItemForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = AgreementItem
        fields = ('title', 'description', 'owner', 'target_date',
                  'status', 'progress', 'priority', 'notes')
        widgets = {
            'target_date': forms.DateInput(attrs={'type': 'date'}),
            'description': forms.Textarea(attrs={'rows': 2}),
            'notes': forms.Textarea(attrs={'rows': 2}),
            'progress': forms.NumberInput(attrs={'min': 0, 'max': 100, 'step': 5}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household:
            self.fields['owner'].queryset = household.members.all()


# ------------- Goals & Projects -------------

class GoalForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Goal
        fields = ('name', 'target_amount', 'currency', 'target_date',
                  'monthly_contribution', 'icon', 'color', 'status', 'notes')
        widgets = {
            'target_date': forms.DateInput(attrs={'type': 'date'}),
            'color': forms.TextInput(attrs={'type': 'color'}),
            'icon': forms.TextInput(attrs={'placeholder': 'bi-piggy-bank'}),
            'notes': forms.Textarea(attrs={'rows': 2}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household and household.base_currency and not self.initial.get('currency'):
            self.fields['currency'].initial = household.base_currency


class GoalContributionForm(BootstrapMixin, forms.ModelForm):
    record_as_expense = forms.BooleanField(
        required=False, initial=False,
        label='Also record this contribution as a household expense',
        help_text='Only check this if the contribution is moving out of your spendable money.'
    )

    class Meta:
        model = GoalContribution
        fields = ('amount', 'date', 'notes')
        widgets = {
            'date': forms.DateInput(attrs={'type': 'date'}),
            'notes': forms.Textarea(attrs={'rows': 2}),
        }


class ReceivableForm(BootstrapMixin, forms.ModelForm):
    record_as_expense = forms.BooleanField(
        required=False, initial=False,
        label='Also record this lending as a household expense',
        help_text='Check this only when first creating a brand-new loan and you want the cash outflow tracked.'
    )

    class Meta:
        model = Receivable
        fields = ('debtor_name', 'debtor_contact', 'description', 'balance', 'original_amount',
                  'currency', 'interest_rate', 'lent_date', 'due_date', 'status', 'notes')
        widgets = {
            'lent_date': forms.DateInput(attrs={'type': 'date'}),
            'due_date': forms.DateInput(attrs={'type': 'date'}),
            'debtor_name': forms.TextInput(attrs={'placeholder': 'Name of the borrower'}),
            'debtor_contact': forms.TextInput(attrs={'placeholder': 'Phone, email (optional)'}),
            'description': forms.TextInput(attrs={'placeholder': 'e.g. tuition, emergency fund'}),
            'notes': forms.Textarea(attrs={'rows': 2}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household and household.base_currency and not self.initial.get('currency'):
            self.fields['currency'].initial = household.base_currency
        # Don't show record_as_expense on edit — only on create.
        if self.instance.pk:
            self.fields.pop('record_as_expense')


class ReceivablePaymentForm(BootstrapMixin, forms.ModelForm):
    record_as_income = forms.BooleanField(
        required=False, initial=True,
        label='Also record this repayment as household income',
    )

    class Meta:
        model = ReceivablePayment
        fields = ('date', 'amount', 'currency', 'notes')
        widgets = {
            'date': forms.DateInput(attrs={'type': 'date'}),
            'notes': forms.Textarea(attrs={'rows': 2}),
        }

    def __init__(self, *args, household=None, receivable=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household and household.base_currency and not self.initial.get('currency'):
            self.fields['currency'].initial = household.base_currency
        if receivable and not self.initial.get('currency'):
            self.fields['currency'].initial = receivable.currency


class ProjectForm(BootstrapMixin, forms.ModelForm):
    class Meta:
        model = Project
        fields = ('name', 'description', 'budget', 'currency',
                  'start_date', 'end_date', 'status', 'color', 'icon')
        widgets = {
            'description': forms.Textarea(attrs={'rows': 3}),
            'start_date': forms.DateInput(attrs={'type': 'date'}),
            'end_date': forms.DateInput(attrs={'type': 'date'}),
            'color': forms.TextInput(attrs={'type': 'color'}),
            'icon': forms.TextInput(attrs={'placeholder': 'bi-bookmark-star'}),
        }

    def __init__(self, *args, household=None, **kwargs):
        super().__init__(*args, **kwargs)
        if household and household.base_currency and not self.initial.get('currency'):
            self.fields['currency'].initial = household.base_currency
