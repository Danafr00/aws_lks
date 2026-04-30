"""
Generate synthetic loan default dataset.
Run this to regenerate or expand the training/validation CSVs.

Usage:
    python prepare_data.py          # generates 300 samples (default)
    python prepare_data.py 500      # generates 500 samples

Output format: SageMaker XGBoost CSV — label first, no header.
Columns: default,age,annual_income,loan_amount,loan_term_months,
         credit_score,employment_years,debt_to_income_ratio,
         has_mortgage,num_credit_lines,num_late_payments
"""
import numpy as np
import sys
import os

np.random.seed(42)

COLUMNS = [
    'default', 'age', 'annual_income', 'loan_amount', 'loan_term_months',
    'credit_score', 'employment_years', 'debt_to_income_ratio',
    'has_mortgage', 'num_credit_lines', 'num_late_payments',
]

def generate_sample(label: int) -> list:
    if label == 0:
        age = np.random.randint(28, 63)
        income = np.random.randint(50000, 165000)
        credit_score = np.random.randint(655, 825)
        employment_years = np.random.randint(4, 31)
        dti = round(np.random.uniform(0.08, 0.33), 2)
        has_mortgage = int(np.random.random() < 0.6)
        loan_term = int(np.random.choice([12, 24, 36]))
        num_lines = np.random.randint(2, 7)
        late = int(np.random.random() < 0.25)
    else:
        age = np.random.randint(21, 37)
        income = np.random.randint(22000, 50000)
        credit_score = np.random.randint(495, 608)
        employment_years = np.random.randint(0, 4)
        dti = round(np.random.uniform(0.43, 0.70), 2)
        has_mortgage = 0
        loan_term = int(np.random.choice([48, 60]))
        num_lines = np.random.randint(6, 15)
        late = np.random.randint(2, 9)

    max_loan = max(5000, int(income * 0.45))
    min_loan = max(3000, int(income * 0.08))
    loan_amount = int(np.random.randint(min_loan, max_loan + 1) / 1000) * 1000
    loan_amount = max(3000, min(50000, loan_amount))

    return [
        label, age, income, loan_amount, loan_term,
        credit_score, employment_years, dti,
        has_mortgage, num_lines, late,
    ]


def generate_dataset(n: int) -> list:
    n_default = int(n * 0.25)
    n_clean = n - n_default
    rows = [generate_sample(0) for _ in range(n_clean)] + \
           [generate_sample(1) for _ in range(n_default)]
    np.random.shuffle(rows)
    return rows


def write_csv(rows: list, path: str):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'w') as f:
        for row in rows:
            f.write(','.join(str(v) for v in row) + '\n')


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    rows = generate_dataset(n)

    split = int(len(rows) * 0.80)
    train_rows = rows[:split]
    val_rows = rows[split:]

    out_dir = os.path.join(os.path.dirname(__file__), '..', 'data')
    write_csv(train_rows, os.path.join(out_dir, 'train.csv'))
    write_csv(val_rows, os.path.join(out_dir, 'validation.csv'))

    default_rate = sum(r[0] for r in rows) / len(rows)
    print(f"Generated {len(rows)} samples (default rate: {default_rate:.1%})")
    print(f"  Train:      {len(train_rows)} rows → {out_dir}/train.csv")
    print(f"  Validation: {len(val_rows)} rows → {out_dir}/validation.csv")


if __name__ == '__main__':
    main()
