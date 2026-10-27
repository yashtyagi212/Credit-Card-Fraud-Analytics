# Credit Card Fraud Analytics & Investigation Prioritisation

**An end-to-end portfolio project combining Python, PostgreSQL, Excel exports and Power BI to analyse fraud patterns and prioritise transactions for investigation.**

The project moves beyond fraud classification to address an operational question: **when investigation capacity is limited, which transactions should be reviewed first?** It combines data-quality auditing, chronological model evaluation, SQL analysis and a two-page Power BI report.

**Key test result:** reviewing the 500 highest-scored transactions identified **73 of 309 fraud cases**, achieving **14.60% precision** and **23.62% recall** across 15,000 test transactions. This was approximately **7.09× the test fraud prevalence**, while still producing 427 false alerts and leaving 236 fraud cases outside the queue.

> This is a historical portfolio study, not a production banking system. Dataset origin is unverified, dates were adjusted to 2025, and transaction amounts are not presented as confirmed financial losses.

## Business Problem

Fraud teams must balance detection coverage against the cost of reviewing legitimate transactions. A model can identify many fraud cases while generating an impractically large number of alerts. Conversely, a restrictive policy can improve precision while missing substantial fraud.

This project addresses four questions:

- Which transaction and customer segments show higher observed fraud rates?
- How do alert thresholds affect fraud detection and investigation workload?
- Which model identifies more fraud at the same review capacity?
- How can analysts inspect a ranked review queue and understand its limitations?

## Technology Stack

| Tool | Role |
|---|---|
| Python, pandas, NumPy | Data audit, preparation, feature review and analysis |
| Matplotlib | Exploratory charts and model evaluation visuals |
| scikit-learn | Preprocessing pipelines, classification and evaluation |
| PostgreSQL, pgAdmin | Data validation, advanced SQL analysis and reporting views |
| Excel / openpyxl | Structured workbook exports for reporting |
| Power BI / DAX | Interactive fraud overview and investigation reporting |
| Jupyter / VS Code | Notebook-based development |
| joblib | Persistence of the fitted preprocessing and model pipeline |

## Dataset

Source: [Credit Card Fraud Detection Dataset 2026 on Kaggle](https://www.kaggle.com/datasets/mohankrishnathalla/credit-card-fraud-detection-dataset-2026).

The following figures describe the dataset used in this project:

| Metric | Value |
|---|---:|
| Transactions | 100,000 |
| Original columns | 43 |
| Unique customers | 8,000 |
| Unique merchants | 3,000 |
| Fraud-labelled transactions | 2,055 |
| Overall fraud rate | 2.055% |
| Duplicate full rows | 0 |
| Total transaction amount | 12,687,197.67 |
| Fraud-labelled transaction amount | 349,209.64 |

Currency and real-bank provenance have not been verified. The data is not claimed to represent Indian banking activity; it may be simulated or date-shifted. Obtain the source dataset separately and check its licence before redistributing it.

## Data Quality and Preparation

| Audit finding | Treatment / scope |
|---|---|
| All source weekday labels mismatched timestamps | Recomputed weekday from the adjusted timestamp |
| 57,158 weekend flags mismatched timestamps | Excluded the weekend field from the retained feature set |
| 41,709 browser values contained literal `N/A` | Preserved as a category; not automatically treated as an error |
| 4,594 records had last-hour amount greater than last-24-hour amount | Documented the inconsistency; excluded these amount-window fields rather than claiming they were corrected |
| Source timestamps used 2026 | Replaced the year with 2025 at project-design stage; preserved month, day and time |
| Outcome-revealing fields were present | Excluded `fraud_type` and `fraud_amount_lost` from model inputs |

Additional requested exclusions included transaction counts over the last 1 hour, 24 hours and 7 days, and `num_chargebacks_ever`. The temporary original-timestamp column was removed from the working output. The raw source file remains the reference for original values.

`is_fraud` is represented as Yes/No in the reporting dataset, 0/1 during modelling and Boolean in PostgreSQL. Transaction, customer, card and merchant IDs, the raw timestamp, and backup columns were excluded from model inputs. Calendar-derived features were retained.

The model input set contained **28 candidate features: 19 numeric and 9 categorical**. Historical aggregates and other contextual flags remain subject to the timing limitations described below.

## Exploratory Findings

| Segment comparison | Observed finding |
|---|---|
| Card not present vs card present | Fraud rates of approximately **2.75% vs 0.80%**; approximately **3.43×** higher for card-not-present transactions |
| Accounts aged 0–90 days vs 91+ days | Fraud rates of approximately **4.85% vs 1.72%**; approximately **2.82×** higher for newer accounts |
| Customer age groups | Rates ranged from approximately **1.88% to 2.17%**, showing limited descriptive variation |
| Monthly pattern | October had the highest observed monthly rate, approximately **2.29%**; June had the lowest, approximately **1.87%** |

These are transaction-level associations within this dataset. They do not establish causation, recurring seasonality or risk levels for a real banking population. Segment rates are interpreted alongside transaction counts.

## Modelling Approach

### Chronological evaluation

Transactions were ordered by timestamp and divided into:

| Partition | Records | Purpose |
|---|---:|---|
| Training | 70,000 | Fit preprocessing and models |
| Validation | 15,000 | Compare models, thresholds and review capacities |
| Test | 15,000 | Evaluate the selected model and review policy |

Timestamp boundaries kept equal timestamps within the same partition. Preprocessing was fitted only on training data.

### Preprocessing and models

- Numeric pipeline: median imputation and standard scaling.
- Categorical pipeline: constant missing-category imputation and one-hot encoding with unknown-category handling.
- Logistic Regression: balanced class weights, `lbfgs`, `max_iter=2000`.
- Random Forest: 300 trees, maximum depth 15, minimum leaf size 10, square-root feature sampling and balanced-subsample class weights.
- Reproducibility setting: `random_state=42` where configured.

These were baseline configurations rather than an exhaustive hyperparameter search. Random Forest used a cloned preprocessing pipeline to keep the fitted models independent.

### Validation model comparison

| Model | Average precision |
|---|---:|
| **Logistic Regression** | **10.85%** |
| Random Forest | 10.13% |

Average precision summarises score-based precision–recall performance. It is reported separately from threshold-specific precision and recall. Validation fraud prevalence was **2.22%**.

At a 0.50 threshold, Logistic Regression achieved **5.67% precision**, **77.48% recall** and **10.57% F1**, flagging **30.33%** of validation transactions. Its high false-alert workload motivated capacity-based evaluation.

### Threshold trade-offs — Logistic Regression, validation

| Threshold | Alerts | Fraud detected | False alerts | Fraud missed | Precision | Recall |
|---:|---:|---:|---:|---:|---:|---:|
| 0.30 | 7,000 | 295 | 6,705 | 38 | 4.21% | 88.59% |
| 0.50 | 4,550 | 258 | 4,292 | 75 | 5.67% | 77.48% |
| 0.70 | 1,747 | 152 | 1,595 | 181 | 8.70% | 45.65% |
| 0.80 | 727 | 99 | 628 | 234 | 13.62% | 29.73% |
| 0.90 | 235 | 51 | 184 | 282 | 21.70% | 15.32% |
| 0.95 | 49 | 12 | 37 | 321 | 24.49% | 3.60% |

Increasing the threshold reduced workload but also reduced fraud coverage. The highest precision alone was not used to choose the final policy.

### Fixed-capacity comparison — validation

| Reviews | Logistic fraud detected | Logistic precision | Logistic recall | Random Forest fraud detected |
|---:|---:|---:|---:|---:|
| 100 | 24 | 24.00% | 7.21% | 24 |
| 250 | 55 | 22.00% | 16.52% | 41 |
| 500 | 82 | 16.40% | 24.62% | 73 |
| 1,000 | 111 | 11.10% | 33.33% | 107 |

Logistic Regression matched or exceeded Random Forest at every tested capacity and was selected for final evaluation. A **500-review budget** was adopted as an illustrative reporting scenario, not as an empirically optimal or bank-confirmed capacity.

## Final Test Results

**Policy:** rank test transactions by Logistic Regression fraud score and select the highest-scored 500. Stable sorting resolves tied scores using the existing chronological row order.

| Metric | Result |
|---|---:|
| Test transactions | 15,000 |
| Actual fraud cases | 309 |
| Selected for review | 500 |
| Fraud detected | 73 |
| False alerts | 427 |
| Fraud not selected | 236 |
| Legitimate transactions not selected | 14,264 |
| Precision@500 | 14.60% |
| Recall@500 | 23.62% |
| Test fraud prevalence | 2.06% |
| Review share of test transactions | 3.33% |

At the same 500-review budget, random selection would be expected to identify approximately **10.3 fraud cases** based on test prevalence. The ranked queue identified 73, corresponding to approximately **7.09× prevalence-based lift**. This comparison is an expectation-based benchmark, not a simulated experiment or a claim of realised financial savings.

The policy still left **76.38% of test fraud outside the queue**, and **85.40% of selected cases were legitimate**. These trade-offs are central to the report.

The top-500 policy applies across the entire test batch. It is not a daily review limit or a real-time deployment policy. Actual fraud labels were used for retrospective evaluation, not ranking.

## PostgreSQL Analysis

The database separates transaction records from test-set predictions:

| Object | Purpose |
|---|---|
| `public.transactions` | 100,000 records with 11 selected analytical fields |
| `public.model_predictions` | 15,000 test scores, review ranks and selection flags |
| `public.vw_monthly_fraud_summary` | Monthly volume, fraud rate and fraudulent amount |
| `public.vw_test_investigation` | Joined test outcomes and investigation reporting |

SQL work includes:

- Import reconciliation, unique entity counts and fraud-rate validation.
- Merchant-category analysis and account-age/card-presence segmentation.
- Month-on-month fraud-rate changes using `LAG()`.
- Merchant prioritisation against category peers, excluding the merchant from its own benchmark.
- Rolling 10-minute customer-activity analysis: the observed maximum was two transactions, so the proposed three-transaction rule returned no matches.
- Spending-spike analysis against strictly earlier customer history, including an optimised cumulative-window implementation.
- Rule coverage, precision and recall calculations.
- Monthly category ranking and cumulative fraudulent-amount contribution.
- Test-only prediction joins that reconcile model outcomes with actual labels.

Historical SQL rules are analytical exercises, not features silently added to the trained model. Full-dataset SQL metrics should not be directly compared with test-only model metrics without matching the evaluation population.

## Power BI Report

The report uses **`Current_Dataset`** and **`Test_Predictions`** from the exported Excel workbook.

### Page 1 — Fraud Risk Overview

- KPI cards: total transactions, fraud transactions, fraud rate and fraudulent transaction amount.
- Monthly fraud-rate trend.
- Fraud rate by merchant category.
- Card-present versus card-not-present comparison.
- Newer versus established account comparison.
- Month and merchant-category slicers.

### Page 2 — Model Performance & Investigation

- KPI cards: selected transactions, detected fraud, review precision, total test fraud and recall.
- Review-queue outcomes: detected fraud versus false alerts.
- Fraud coverage: detected versus missed fraud.
- Within-class score distributions for fraud and legitimate transactions.
- Top five merchant categories by false-alert count.
- Investigation table sorted by review rank, with transaction date, amount, merchant category and score.

Only the investigation table is restricted to selected records; the full page must retain all test transactions so recall and missed fraud remain meaningful. Scores are displayed as ranking scores rather than calibrated probabilities. Date fields use the actual date instead of an expanded hierarchy, and score/rank totals are disabled.

## Repository Organisation

The intended repository layout is below. Notebook and SQL filenames may differ; run them in the sequence described in the next section.

| Location | Contents |
|---|---|
| `data/raw/` | Original source CSV, subject to source licence |
| `data/processed/` | Reporting and PostgreSQL import exports |
| `notebooks/` | Audit, EDA, preparation, modelling and export notebooks |
| `sql/` | Table definitions, validation, analysis and reporting views |
| `excel/fraud_analytics_results.xlsx` | Reporting workbook |
| `models/fraud_logistic_pipeline.joblib` | Fitted preprocessing and Logistic Regression pipeline |
| `powerbi/Credit_Card_Fraud_Analytics.pbix` | Power BI report |
| `reports/` | Evaluation CSVs, model metadata and dashboard screenshots |
| `README.md` | Project overview and methodology |

### Principal exports

| File | Contents |
|---|---|
| `test_predictions.csv` | All test transactions, scores, actual outcomes, rank and selection flag |
| `investigation_queue.csv` | Top-500 review records |
| `transactions_postgresql.csv` | Transaction import in database column order |
| `model_predictions_postgresql.csv` | Prediction import in database column order |
| `validation_model_comparison.csv` | Model-level validation AP |
| `validation_capacity_comparison.csv` | Model comparison at fixed review budgets |
| `test_capacity_report.csv` | Final test review-policy results |
| `model_metadata.json` | Feature list, selected policy, metrics and limitations |

## Reproducing the Workflow

1. Download the source CSV from Kaggle and place it in `data/raw/`. Preserve the original file.
2. Create a Python environment and install the notebook dependencies:

   ```bash
   python -m venv .venv
   python -m pip install pandas numpy matplotlib scikit-learn jupyter ipykernel openpyxl joblib
   ```

   Activate the environment before installation and select that interpreter as the notebook kernel. Exact original package versions were not captured in this README; record the working environment before attempting strict reproduction.

3. Run the notebooks in order: load and audit; apply documented changes; EDA; chronological split; feature selection; preprocessing; model training; validation comparison; frozen-policy test evaluation; exports.
4. Use a clean notebook session when validating reproducibility. Recreate dependent variables in order after a kernel restart.
5. Create the PostgreSQL tables, then import the matching CSVs with **CSV header enabled**. Load transactions before predictions because predictions reference transaction IDs.
6. Confirm transaction counts of **100,000 / 2,055 fraud** and prediction counts of **15,000 / 500 selected**. Run SQL analysis and create reporting views.
7. Open the Power BI report, update the workbook source path and refresh. Confirm that all-data overview metrics and test-only model metrics match the tables above.

To reload the saved model without retraining:

```python
import joblib

pipeline = joblib.load("models/fraud_logistic_pipeline.joblib")
fraud_index = list(pipeline.classes_).index(1)
scores = pipeline.predict_proba(X_new)[:, fraud_index]
```

`X_new` must contain the expected input columns and compatible types; the pipeline handles fitted preprocessing. Load only trusted model files.

## Limitations

- **Unverified provenance:** no claim of real-bank, Indian or production transaction data.
- **Adjusted dates:** 2025 is an analysis convention, not evidence that transactions genuinely occurred in that year.
- **Prior exploratory exposure:** full-dataset EDA preceded the chronological split. The test period is therefore not claimed to be completely untouched by exploratory analysis, although subsequent model/policy selection used validation results.
- **Feature timing:** the source generation logic for historical averages, prior declines, distances and contextual risk flags is unverified. Their availability at the intended prediction time requires further validation before operational use.
- **Uncalibrated scores:** class-weighted model scores support ranking but are not established fraud probabilities.
- **Illustrative capacity:** the 500-review batch budget is not tied to a confirmed staffing model, review cost or daily service level.
- **Limited modelling scope:** two baseline configurations were compared; no exhaustive tuning, calibration or external validation is claimed.
- **Historical outcomes:** dashboard outcomes describe retrospective results. They are not live investigation statuses, blocked payments or confirmed recoveries.
- **Financial interpretation:** currency is unverified, and fraudulent transaction amount is not equivalent to actual loss or savings.

## Potential Extensions

- Validate feature availability and rebuild history features from strictly prior events.
- Evaluate additional temporal folds and reserve a fresh evaluation period.
- Test calibrated scores and stronger models using training/validation data only.
- Simulate daily review budgets and include explicit investigation costs.
- Add drift monitoring, investigation feedback and documented analyst outcomes.

## Author

**Yash Tyagi** — Data Analytics Portfolio

This project demonstrates data-quality assessment, SQL analytics, imbalanced classification, capacity-based evaluation and business-focused reporting.
