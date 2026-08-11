// Copies FASTQ files from Illumina BaseSpace Sequence Hub into an APGAP
// batch-upload endpoint bucket (`gs://batch-upload-lab*`), which triggers
// the APGAP compliance scrubber cascade (Pub/Sub OBJECT_FINALIZE → DLP
// scan → SRA human-read scrubber → lab bucket).
//
// Design notes:
// - Two processes so each uses a purpose-built container: `bs` CLI in
//   theiagen/basespace_cli for the BaseSpace download, gcloud/gsutil in
//   google/cloud-sdk for the compliance-bucket upload. Nextflow's work-
//   bucket staging shuttles files between them.
// - The batch-upload endpoint's scoped SA key is a Seqera Pipeline Secret
//   (BATCH_UPLOAD_SA_KEY_B64, base64-encoded). Materialized to a tmp file
//   inside the UPLOAD_TO_INGEST container, then activated via `gcloud
//   auth activate-service-account` (needed for gsutil CLI) AND set as
//   GOOGLE_APPLICATION_CREDENTIALS (needed for ADC-consuming clients).
// - Uploads use explicit `gsutil cp`, NOT `publishDir`. Verified in a
//   preflight test that Nextflow's publishDir to a gs:// URI runs from
//   the head process (compute env's seqera-sa identity), which cannot
//   write to the scoped batch-upload bucket. An in-script auth switch
//   only affects commands the script itself runs — hence gsutil cp.

nextflow.enable.dsl=2

params.input_files = null    // List of BaseSpace file IDs (from `bs contents project`)
params.outdir      = null    // gs:// URI of the batch-upload endpoint bucket (from APGAP Portal)

workflow {
    if (!params.input_files) {
        error "params.input_files is required (list of BaseSpace file IDs to download)"
    }
    if (!params.outdir) {
        error "params.outdir is required (gs://batch-upload-lab*-* URI from APGAP Portal endpoint)"
    }
    if (!(params.outdir ==~ /^gs:\/\/batch-upload-lab.*$/)) {
        log.warn "params.outdir does not match the expected batch-upload bucket pattern (gs://batch-upload-lab*). Continuing anyway, but scrubber cascade only fires on that pattern."
    }

    log.info "BaseSpace files to copy: ${params.input_files.size()}"
    log.info "Destination (batch-upload endpoint): ${params.outdir}"

    channel.fromList(params.input_files).set { bs_files_ch }
    DOWNLOAD_FROM_BS(bs_files_ch)
    UPLOAD_TO_INGEST(DOWNLOAD_FROM_BS.out.downloaded)
}

process DOWNLOAD_FROM_BS {

    container 'theiagen/basespace_cli:1.2.1'

    // Seqera injects this Pipeline Secret as an env var in the task container.
    // Value: BaseSpace API access token (from `~/.basespace/default.cfg` on a
    // `bs auth`ed machine, or from the BaseSpace developer portal).
    secret 'BASESPACE_ACCESS_TOKEN'

    input:
    val(bs_file_id)

    output:
    path("*.fastq.gz"), emit: downloaded

    script:
    """
    # bs CLI reads BASESPACE_ACCESS_TOKEN from the environment.
    export BASESPACE_API_SERVER=https://api.basespace.illumina.com
    bs download file -i ${bs_file_id} --output ./
    """
}

process UPLOAD_TO_INGEST {

    container 'google/cloud-sdk:latest'

    // Seqera injects this Pipeline Secret as an env var. Value: the scoped
    // batch-upload SA key JSON, base64-encoded (Nextflow Secrets are env-var-
    // only, so multi-line JSON must be encoded).
    // Rotate this Secret per endpoint or per run — the key is short-lived
    // and scoped to a single ingest bucket.
    secret 'BATCH_UPLOAD_SA_KEY_B64'

    input:
    path(file_to_upload)

    script:
    """
    # Materialize the scoped SA key from the Secret env var to a file
    echo "\$BATCH_UPLOAD_SA_KEY_B64" | base64 -d > /tmp/sa.json
    chmod 600 /tmp/sa.json

    # Activate the scoped SA. Two mechanisms because they cover different clients:
    # - `gcloud auth activate-service-account` sets gcloud/gsutil's active identity
    # - GOOGLE_APPLICATION_CREDENTIALS satisfies any ADC-aware client / library
    gcloud auth activate-service-account --key-file=/tmp/sa.json --quiet
    export GOOGLE_APPLICATION_CREDENTIALS=/tmp/sa.json

    # Upload to the batch-upload endpoint bucket. This write triggers the
    # scrubber cascade (Pub/Sub OBJECT_FINALIZE → DLP scan → SRA scrubber
    # → lab bucket). The file will disappear from the ingest bucket within
    # a few minutes after upload as the cascade moves it downstream.
    gsutil cp "${file_to_upload}" "${params.outdir}"

    # Defense in depth: remove the key material from the task VM before exit.
    rm /tmp/sa.json
    """
}
