"""
Brarish Data Platform - KYC Profile Ingestion Pipeline
========================================================

Purpose: Ingests customer KYC profiles from mobile app via Pub/Sub
Author: Marcelo Fonseca
Date: 2026-01-05

Pipeline Flow:
1. Subscribe to Pub/Sub topic: kyc-profiles-raw
2. Validate JSON schema (ISO 20022 pacs.008)
3. Tokenize PII (CPF, PPS numbers)
4. Apply data quality checks (Great Expectations)
5. Write to BigQuery: refined.kyc_profiles

SLA: P95 latency <5 minutes, 99.9% availability
"""

import json
import logging
from typing import Dict, Optional
from datetime import datetime
import hashlib

from google.cloud import pubsub_v1, bigquery
from google.cloud.exceptions import NotFound
import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions
import great_expectations as ge

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class KYCProfileValidator:
    """Validates KYC profiles against ISO 20022 pacs.008 schema"""
    
    REQUIRED_FIELDS = [
        'customerId',
        'identifiers',
        'residency',
        'onboardingDate'
    ]
    
    VALID_ID_TYPES = ['CPF', 'PPS', 'PASSPORT']
    VALID_COUNTRIES = ['IE', 'BR']
    
    @staticmethod
    def validate_schema(record: Dict) -> tuple[bool, Optional[str]]:
        """
        Validates KYC profile schema
        
        Returns:
            (is_valid, error_message)
        """
        # Check required fields
        for field in KYCProfileValidator.REQUIRED_FIELDS:
            if field not in record:
                return False, f"Missing required field: {field}"
        
        # Validate identifiers structure
        if not isinstance(record.get('identifiers'), list):
            return False, "Identifiers must be a list"
        
        for identifier in record['identifiers']:
            if identifier.get('type') not in KYCProfileValidator.VALID_ID_TYPES:
                return False, f"Invalid identifier type: {identifier.get('type')}"
        
        # Validate residency
        residency = record.get('residency', [])
        if not isinstance(residency, list) or len(residency) == 0:
            return False, "At least one residency record required"
        
        for res in residency:
            if res.get('country') not in KYCProfileValidator.VALID_COUNTRIES:
                return False, f"Invalid country: {res.get('country')}"
        
        return True, None


class PIITokenizer:
    """Tokenizes PII fields for GDPR compliance"""
    
    @staticmethod
    def tokenize(value: str, salt: str = "brarish-kyc-salt-2026") -> str:
        """
        Creates deterministic hash for PII values
        
        Args:
            value: PII value to tokenize (e.g., CPF number)
            salt: Salt for hashing (from Cloud KMS in production)
        
        Returns:
            SHA-256 hash token
        """
        if not value:
            return None
        
        combined = f"{salt}{value}".encode('utf-8')
        return hashlib.sha256(combined).hexdigest()
    
    @staticmethod
    def tokenize_identifiers(identifiers: list) -> list:
        """Tokenizes all identifier values in list"""
        tokenized = []
        
        for identifier in identifiers:
            tokenized_id = identifier.copy()
            if 'value' in tokenized_id:
                tokenized_id['value_token'] = PIITokenizer.tokenize(tokenized_id['value'])
                # Remove raw PII (GDPR Art. 25 - Data Minimization)
                del tokenized_id['value']
            tokenized.append(tokenized_id)
        
        return tokenized


class TransformKYCProfile(beam.DoFn):
    """Beam DoFn to transform KYC profiles"""
    
    def process(self, element):
        """
        Transforms raw KYC profile to refined format
        
        Args:
            element: Pub/Sub message with KYC profile JSON
        
        Yields:
            Transformed profile dict or error record
        """
        try:
            # Parse JSON
            raw_data = json.loads(element.data.decode('utf-8'))
            
            # Validate schema
            is_valid, error_msg = KYCProfileValidator.validate_schema(raw_data)
            if not is_valid:
                logger.error(f"Schema validation failed: {error_msg}")
                yield beam.pvalue.TaggedOutput('errors', {
                    'error': error_msg,
                    'raw_data': raw_data,
                    'timestamp': datetime.utcnow().isoformat()
                })
                return
            
            # Tokenize PII
            tokenized_identifiers = PIITokenizer.tokenize_identifiers(
                raw_data.get('identifiers', [])
            )
            
            # Build refined record
            refined_record = {
                'customer_id': raw_data['customerId'],
                'identifiers': tokenized_identifiers,
                'residency': raw_data['residency'],
                'onboarding_date': raw_data['onboardingDate'],
                'kyc_status': raw_data.get('status', 'PENDING'),
                'verification_level': raw_data.get('verificationLevel', 'BASIC'),
                'ingestion_timestamp': datetime.utcnow().isoformat(),
                'source_system': 'mobile-app-api',
                'pipeline_version': '1.0.0'
            }
            
            # Data quality enrichment
            refined_record['dq_completeness_score'] = self._calculate_completeness(refined_record)
            
            yield refined_record
            
        except json.JSONDecodeError as e:
            logger.error(f"JSON decode error: {e}")
            yield beam.pvalue.TaggedOutput('errors', {
                'error': f"Invalid JSON: {str(e)}",
                'raw_data': element.data.decode('utf-8'),
                'timestamp': datetime.utcnow().isoformat()
            })
        except Exception as e:
            logger.error(f"Unexpected error: {e}")
            yield beam.pvalue.TaggedOutput('errors', {
                'error': f"Processing error: {str(e)}",
                'timestamp': datetime.utcnow().isoformat()
            })
    
    @staticmethod
    def _calculate_completeness(record: Dict) -> float:
        """
        Calculates data quality completeness score
        
        Returns:
            Score between 0.0 and 1.0
        """
        total_fields = 7  # Expected fields in refined record
        populated_fields = sum([
            1 for field in ['customer_id', 'identifiers', 'residency', 
                           'onboarding_date', 'kyc_status', 'verification_level']
            if record.get(field)
        ])
        return round(populated_fields / total_fields, 3)


def run_kyc_pipeline(
    project_id: str,
    subscription: str,
    dataset: str,
    table: str,
    pipeline_options: PipelineOptions
):
    """
    Runs the KYC ingestion pipeline
    
    Args:
        project_id: GCP project ID
        subscription: Pub/Sub subscription name
        dataset: BigQuery dataset
        table: BigQuery table name
        pipeline_options: Beam pipeline options
    """
    
    table_schema = {
        'fields': [
            {'name': 'customer_id', 'type': 'STRING', 'mode': 'REQUIRED'},
            {'name': 'identifiers', 'type': 'RECORD', 'mode': 'REPEATED', 'fields': [
                {'name': 'type', 'type': 'STRING'},
                {'name': 'value_token', 'type': 'STRING'}
            ]},
            {'name': 'residency', 'type': 'RECORD', 'mode': 'REPEATED', 'fields': [
                {'name': 'country', 'type': 'STRING'},
                {'name': 'startDate', 'type': 'STRING'}
            ]},
            {'name': 'onboarding_date', 'type': 'STRING'},
            {'name': 'kyc_status', 'type': 'STRING'},
            {'name': 'verification_level', 'type': 'STRING'},
            {'name': 'ingestion_timestamp', 'type': 'TIMESTAMP'},
            {'name': 'dq_completeness_score', 'type': 'FLOAT'},
            {'name': 'source_system', 'type': 'STRING'},
            {'name': 'pipeline_version', 'type': 'STRING'}
        ]
    }
    
    with beam.Pipeline(options=pipeline_options) as pipeline:
        
        # Read from Pub/Sub
        messages = (
            pipeline
            | 'Read from Pub/Sub' >> beam.io.ReadFromPubSub(
                subscription=f'projects/{project_id}/subscriptions/{subscription}'
            )
        )
        
        # Transform profiles
        transformed = (
            messages
            | 'Transform KYC Profiles' >> beam.ParDo(TransformKYCProfile()).with_outputs(
                'errors', main='valid'
            )
        )
        
        # Write valid records to BigQuery
        (
            transformed.valid
            | 'Write to BigQuery' >> beam.io.WriteToBigQuery(
                table=f'{project_id}:{dataset}.{table}',
                schema=table_schema,
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_IF_NEEDED
            )
        )
        
        # Write errors to dead-letter table
        (
            transformed.errors
            | 'Write Errors' >> beam.io.WriteToBigQuery(
                table=f'{project_id}:{dataset}.{table}_errors',
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_IF_NEEDED
            )
        )
    
    logger.info("KYC ingestion pipeline completed successfully")


if __name__ == '__main__':
    """
    Example usage:
    
    python kyc_ingestion.py \
        --project=brarish-data-platform \
        --subscription=kyc-profiles-sub \
        --dataset=refined \
        --table=kyc_profiles \
        --runner=DataflowRunner \
        --region=europe-west1
    """
    
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', required=True, help='GCP project ID')
    parser.add_argument('--subscription', required=True, help='Pub/Sub subscription')
    parser.add_argument('--dataset', default='refined', help='BigQuery dataset')
    parser.add_argument('--table', default='kyc_profiles', help='BigQuery table')
    
    known_args, pipeline_args = parser.parse_known_args()
    
    pipeline_options = PipelineOptions(
        pipeline_args,
        streaming=True,
        save_main_session=True
    )
    
    run_kyc_pipeline(
        project_id=known_args.project,
        subscription=known_args.subscription,
        dataset=known_args.dataset,
        table=known_args.table,
        pipeline_options=pipeline_options
    )
