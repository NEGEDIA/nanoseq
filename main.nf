#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/nanoseq
========================================================================================
 nf-core/nanoseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/nanoseq
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

      nextflow run nf-core/nanoseq \
          --input samplesheet.csv \
          --protocol DNA \
          --run_dir ./fast5/ \
          --flowcell FLO-MIN106 \
          --kit SQK-LSK109 \
          --barcode_kit SQK-PBK004 \
          -profile docker

    Mandatory arguments
      --input [file]                  Comma-separated file containing information about the samples in the experiment (see docs/usage.md)
      --protocol [str]                Specifies the type of data that was sequenced i.e. "DNA", "cDNA" or "directRNA"
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: docker, singularity, awsbatch, test and more.

    Basecalling/Demultiplexing
      --run_dir [file]                Path to Nanopore run directory (e.g. fastq_pass/)
      --flowcell [str]                Flowcell used to perform the sequencing e.g. FLO-MIN106. Not required if '--guppy_config' is specified
      --kit [str]                     Kit used to perform the sequencing e.g. SQK-LSK109. Not required if '--guppy_config' is specified
      --barcode_kit [str]             Barcode kit used to perform the sequencing e.g. SQK-PBK004
      --guppy_config [file]           Guppy config file used for basecalling. Cannot be used in conjunction with '--flowcell' and '--kit'
      --guppy_gpu [bool]              Whether to perform basecalling with Guppy in GPU mode (Default: false)
      --guppy_gpu_runners [int]       Number of '--gpu_runners_per_device' used for guppy when using '--guppy_gpu' (Default: 6)
      --guppy_cpu_threads [int]       Number of '--cpu_threads_per_caller' used for guppy when using '--guppy_gpu' (Default: 1)
      --gpu_device [str]              Basecalling device specified to Guppy in GPU mode using '--device' (Default: 'auto')
      --gpu_cluster_options [str]     Cluster options required to use GPU resources (e.g. '--part=gpu --gres=gpu:1')
      --skip_basecalling [bool]       Skip basecalling with Guppy (Default: false)
      --skip_demultiplexing [bool]    Skip demultiplexing with Guppy (Default: false)

    Alignment
      --stranded [bool]               Specifies if the data is strand-specific. Automatically activated when using --protocol directRNA (Default: false)
      --aligner [str]                 Specifies the aligner to use (available are: minimap2 or graphmap) (Default: 'minimap2')
      --save_align_intermeds [bool]   Save the .sam files from the alignment step (Default: false)
      --skip_alignment [bool]         Skip alignment and subsequent process (Default: false)

    Coverage tracks
      --skip_bigwig [bool]            Skip BigWig file generation (Default: false)
      --skip_bigbed [bool]            Skip BigBed file generation (Default: false)

    QC
      --skip_qc [bool]                Skip all QC steps apart from MultiQC (Default: false)
      --skip_pycoqc [bool]            Skip pycoQC (Default: false)
      --skip_nanoplot [bool]          Skip NanoPlot (Default: false)
      --skip_fastqc [bool]            Skip FastQC (Default: false)
      --skip_multiqc [bool]           Skip MultiQC (Default: false)

    Other
      --outdir [file]                 The output directory where the results will be saved (Default: '/results')
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful (Default: false)
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on (Default: 'eu-west-1')
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */
if (params.input)               { ch_input = file(params.input, checkIfExists: true) } else { exit 1, "Samplesheet file not specified!" }

if (!params.skip_basecalling) {

    // TODO nf-core: Add in a check to see if running offline
    // Pre-download test-dataset to get files for '--run_dir' parameter
    // Nextflow is unable to recursively download directories via HTTPS
    if (workflow.profile.split(',').contains('test')) {
        process GetTestData {

            output:
            file "test-datasets/fast5/" into ch_run_dir

            script:
            """
            git clone https://github.com/nf-core/test-datasets.git --branch nanoseq --single-branch
            """
        }
    } else {
        if (params.run_dir)         { ch_run_dir = Channel.fromPath(params.run_dir, checkIfExists: true) } else { exit 1, "Please specify a valid run directory!" }
        if (!params.guppy_config)   {
            if (!params.flowcell)   { exit 1, "Please specify a valid flowcell identifier for basecalling!" }
            if (!params.kit)        { exit 1, "Please specify a valid kit identifier for basecalling!" }
       }
    }
} else {
    // Cannot demultiplex without performing basecalling
    // Skip demultiplexing if barcode kit isnt provided
    if (!params.barcode_kit) {
        params.skip_demultiplexing = true
    }
}

if (!params.skip_alignment) {
    if (params.aligner != 'minimap2' && params.aligner != 'graphmap') {
        exit 1, "Invalid aligner option: ${params.aligner}. Valid options: 'minimap2', 'graphmap'"
    }
    if (params.protocol != 'DNA' && params.protocol != 'cDNA' && params.protocol != 'directRNA') {
      exit 1, "Invalid protocol option: ${params.protocol}. Valid options: 'DNA', 'cDNA', 'directRNA'"
    }
}

// Stage config files
ch_multiqc_config = file(params.multiqc_config, checkIfExists: true)
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']               = custom_runName ?: workflow.runName
summary['Samplesheet']            = params.input
summary['Protocol']               = params.protocol
summary['Stranded']               = (params.stranded || params.protocol == 'directRNA') ? 'Yes' : 'No'
summary['Skip Basecalling']       = params.skip_basecalling ? 'Yes' : 'No'
summary['Skip Demultiplexing']    = params.skip_demultiplexing ? 'Yes' : 'No'
if (!params.skip_basecalling) {
    summary['Run Dir']            = params.run_dir
    summary['Flowcell ID']        = params.flowcell ?: 'Not required'
    summary['Kit ID']             = params.kit ?: 'Not required'
    summary['Barcode Kit ID']     = params.barcode_kit ?: 'Unspecified'
    summary['Guppy Config File']  = params.guppy_config ?: 'Unspecified'
    summary['Guppy GPU Mode']     = params.guppy_gpu ? 'Yes' : 'No'
    summary['Guppy GPU Runners']  = params.guppy_gpu_runners
    summary['Guppy CPU Threads']  = params.guppy_cpu_threads
    summary['Guppy GPU Device']   = params.gpu_device ?: 'Unspecified'
    summary['Guppy GPU Options']  = params.gpu_cluster_options ?: 'Unspecified'
}
summary['Skip Alignment']         = params.skip_alignment ? 'Yes' : 'No'
if (!params.skip_alignment) {
    summary['Aligner']            = params.aligner
    summary['Save Intermeds']     = params.save_align_intermeds ? 'Yes' : 'No'
}
summary['Skip BigBed']            = params.skip_bigbed ? 'Yes' : 'No'
summary['Skip BigWig']            = params.skip_bigwig ? 'Yes' : 'No'
summary['Skip QC']                = params.skip_qc ? 'Yes' : 'No'
summary['Skip pycoQC']            = params.skip_pycoqc ? 'Yes' : 'No'
summary['Skip NanoPlot']          = params.skip_nanoplot ? 'Yes' : 'No'
summary['Skip FastQC']            = params.skip_fastqc ? 'Yes' : 'No'
summary['Skip MultiQC']           = params.skip_multiqc ? 'Yes' : 'No'
summary['Max Resources']          = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']             = params.outdir
summary['Launch dir']             = workflow.launchDir
summary['Working dir']            = workflow.workDir
summary['Script dir']             = workflow.projectDir
summary['User']                   = workflow.userName
if (workflow.profile == 'awsbatch') {
    summary['AWS Region']         = params.awsregion
    summary['AWS Queue']          = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']     = params.email
    summary['E-mail on failure']  = params.email_on_fail
    summary['MultiQC maxsize']    = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(19)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

/*
 * PREPROCESSING - CHECK SAMPLESHEET
 */
process CheckSampleSheet {
    tag "$samplesheet"
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file samplesheet from ch_input

    output:
    file "*.csv" into ch_samplesheet_reformat

    script:  // This script is bundled with the pipeline, in nf-core/nanoseq/bin/
    demultiplex = params.skip_demultiplexing ? '--skip_demultiplexing' : ''
    """
    check_samplesheet.py \\
        $samplesheet \\
        samplesheet_reformat.csv \\
        $demultiplex
    """
}

// Function to see if fasta file exists in iGenomes
def get_fasta(genome, genomeMap) {
    def fasta = null
    if (genome) {
        if (genomeMap.containsKey(genome)) {
            fasta = file(genomeMap[genome].fasta, checkIfExists: true)
        } else {
            fasta = file(genome, checkIfExists: true)
        }
    }
    return fasta
}

if (params.skip_basecalling) {

    ch_guppy_version = Channel.empty()
    ch_pycoqc_version = Channel.empty()

    // Create channels = [genome_fasta, sample, fastq]
    ch_samplesheet_reformat
        .splitCsv(header:true, sep:',')
        .map { row -> [ get_fasta(row.genome, params.genomes), row.sample, file(row.fastq, checkIfExists: true) ] }
        .into { ch_fastq_nanoplot;
                ch_fastq_fastqc;
                ch_fastq_index;
                ch_fastq_align }

} else {

    // Create channels = [genome_fasta, barcode, sample]
    ch_samplesheet_reformat
        .splitCsv(header:true, sep:',')
        .map { row -> [ get_fasta(row.genome, params.genomes), row.barcode, row.sample ] }
        .into { ch_sample_info;
                ch_sample_name }

    // Get sample name for single sample when --skip_demultiplexing
    ch_sample_name
        .first()
        .map { it[-1] }
        .set { ch_sample_name }

    /*
     * STEP 1 - Basecalling and demultipexing using Guppy
     */
    process Guppy {
        tag "$run_dir"
        label 'process_high'
        clusterOptions = params.gpu_cluster_options
        publishDir path: "${params.outdir}/guppy", mode: 'copy',
            saveAs: { filename ->
                          if (!filename.endsWith(".version")) filename
                    }

        input:
        file run_dir from ch_run_dir
        val name from ch_sample_name

        output:
        file "fastq/*.fastq.gz" into ch_guppy_fastq
        file "basecalling/*.txt" into ch_guppy_pycoqc_summary,
                                      ch_guppy_nanoplot_summary
        file "basecalling/*"
        file "*.version" into ch_guppy_version

        script:
        barcode_kit = params.barcode_kit ? "--barcode_kits $params.barcode_kit" : ""
        config = params.guppy_config ? "--config $params.guppy_config" : "--flowcell $params.flowcell --kit $params.kit"
        proc_options = params.guppy_gpu ? "--device $params.gpu_device --num_callers $task.cpus --cpu_threads_per_caller $params.guppy_cpu_threads --gpu_runners_per_device $params.guppy_gpu_runners" : "--num_callers 2 --cpu_threads_per_caller ${task.cpus/2}"
        """
        guppy_basecaller \\
            --input_path $run_dir \\
            --save_path ./basecalling \\
            --records_per_fastq 0 \\
            --compress_fastq \\
            $barcode_kit \\
            $config \\
            $proc_options
        guppy_basecaller --version &> guppy.version

        ## Concatenate fastq files
        mkdir fastq
        cd basecalling
        if [ "\$(find . -type d -name "barcode*" )" != "" ]
        then
            for dir in barcode*/
            do
                dir=\${dir%*/}
                cat \$dir/*.fastq.gz > ../fastq/\$dir.fastq.gz
            done
        else
            cat *.fastq.gz > ../fastq/${name}.fastq.gz
        fi
        """
    }

    /*
     * STEP 2 - QC using PycoQC
     */
    process PycoQC {
        tag "$summary_txt"
        label 'process_low'
        publishDir "${params.outdir}/pycoqc", mode: 'copy',
            saveAs: { filename ->
                          if (!filename.endsWith(".version")) filename
                    }

        when:
        !params.skip_qc && !params.skip_pycoqc

        input:
        file summary_txt from ch_guppy_pycoqc_summary

        output:
        file "*.html"
        file "*.version" into ch_pycoqc_version

        script:
        """
        pycoQC -f $summary_txt -o pycoQC_output.html
        pycoQC --version &> pycoqc.version
        """
    }

    /*
     * STEP 3 - QC using NanoPlot
     */
    process NanoPlotSummary {
        tag "$summary_txt"
        label 'process_low'
        publishDir "${params.outdir}/nanoplot/summary", mode: 'copy'

        when:
        !params.skip_qc && !params.skip_nanoplot

        input:
        file summary_txt from ch_guppy_nanoplot_summary

        output:
        file "*.{png,html,txt,log}"

        script:
        """
        NanoPlot -t $task.cpus --summary $summary_txt
        """
    }

    // Create channels = [genome_fasta, sample, fastq]
    ch_guppy_fastq
        .flatten()
        .map { it -> [ it, it.baseName.substring(0,it.baseName.lastIndexOf('.')) ] } // [barcode001.fastq, barcode001]
        .join(ch_sample_info, by: 1) // join on barcode
        .map { it -> [ it[2], it[3], it[1] ] }
        .into { ch_fastq_nanoplot;
                ch_fastq_fastqc;
                ch_fastq_index;
                ch_fastq_align }
}

/*
 * STEP 4 - FastQ QC using NanoPlot
 */
process NanoPlotFastQ {
    tag "$sample"
    label 'process_low'
    publishDir "${params.outdir}/nanoplot/fastq/${sample}", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }

    when:
    !params.skip_qc && !params.skip_nanoplot

    input:
    set val(fasta), val(sample), file(fastq) from ch_fastq_nanoplot

    output:
    file "*.{png,html,txt,log}"
    file "*.version" into ch_nanoplot_version

    script:
    """
    NanoPlot -t $task.cpus --fastq $fastq
    NanoPlot --version &> nanoplot.version
    """
}

/*
 * STEP 5 - FastQ QC using FastQC
 */
process FastQC {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }

    when:
    !params.skip_fastqc && !params.skip_qc

    input:
    set val(fasta), val(sample), file(fastq) from ch_fastq_fastqc

    output:
    file "*.{zip,html}" into ch_fastqc_mqc
    file "*.version" into ch_fastqc_version

    script:
    """
    fastqc -q -t $task.cpus $fastq
    mv ${fastq.simpleName}_fastqc.html ${sample}_fastqc.html
    mv ${fastq.simpleName}_fastqc.zip ${sample}_fastqc.zip
    fastqc --version &> fastqc.version
    """
}

if (params.skip_alignment) {

    ch_samtools_version = Channel.empty()
    ch_minimap2_version = Channel.empty()
    ch_graphmap_version = Channel.empty()
    ch_bedtools_version = Channel.empty()
    ch_sortbam_stats_mqc = Channel.empty()

} else {

    // Get unique list of all genome fasta files
    ch_fastq_index
        .map { it -> [ it[0].toString(), it[0] ] }  // [str(genome_fasta), genome_fasta]
        .filter { it[1] != null }
        .unique()
        .into { ch_fasta_sizes;
                ch_fasta_index;
                ch_fasta_align }

    /*
     * STEP 6 - Make chromosome sizes file
     */
    process GetChromSizes {
        tag "$fasta"

        input:
        set val(name), file(fasta) from ch_fasta_sizes

        output:
        set val(name), file("*.sizes") into ch_chrom_sizes
        file "*.version" into ch_samtools_version

        script:
        """
        samtools faidx $fasta
        cut -f 1,2 ${fasta}.fai > ${fasta}.sizes
        samtools --version &> samtools.version
        """
    }

    /*
     * STEP 7 - Create genome index
     */
    if (params.aligner == 'minimap2') {

        process MiniMap2Index {
          tag "$fasta"
          label 'process_medium'

          input:
          set val(name), file(fasta) from ch_fasta_index

          output:
          set val(name), file("*.mmi") into ch_index
          file "*.version" into ch_minimap2_version

          script:
          minimap_preset = (params.protocol == 'DNA') ? "-ax map-ont" : "-ax splice"
          kmer = (params.protocol == 'directRNA') ? "-k14" : ""
          stranded = (params.stranded || params.protocol == 'directRNA') ? "-uf" : ""
          """
          minimap2 $minimap_preset $kmer $stranded -t $task.cpus -d ${fasta}.mmi $fasta
          minimap2 --version &> minimap2.version
          """
        }
        ch_graphmap_version = Channel.empty()

    } else if (params.aligner == 'graphmap') {

        // TODO nf-core: Create graphmap index with GTF instead
        // gtf = (params.protocol == 'directRNA' && params.gtf) ? "--gtf $gtf" : ""
        process GraphMapIndex {
          tag "$fasta"
          label 'process_medium'

          input:
          set val(name), file(fasta) from ch_fasta_index

          output:
          set val(name), file("*.gmidx") into ch_index
          file "*.version" into ch_graphmap_version

          script:
          """
          graphmap align -t $task.cpus -I -r $fasta
          echo \$(graphmap 2>&1) > graphmap.version
          """
        }
        ch_minimap2_version = Channel.empty()
    }

    // Convert genome_fasta to string from file to use cross()
    ch_fastq_align
        .map { it -> [ it[0].toString(), it[1], it[2] ] }
        .set { ch_fastq_align }

    // Create channels = [genome_fasta, index, sizes, sample, fastq]
    ch_fasta_align
        .join(ch_index)
        .join(ch_chrom_sizes)
        .cross(ch_fastq_align)
        .flatten()
        .collate(7)
        .map { it -> [ it[1], it[2], it[3], it[5], it[6] ] }
        .set { ch_fastq_align }

    /*
     * STEP 8 - Align fastq files
     */
    if (params.aligner == 'minimap2') {

        process MiniMap2Align {
            tag "$sample"
            label 'process_medium'
            if (params.save_align_intermeds) {
                publishDir path: "${params.outdir}/${params.aligner}", mode: 'copy',
                    saveAs: { filename ->
                                  if (filename.endsWith(".sam")) filename
                            }
            }

            input:
            set file(fasta), file(index), file(sizes), val(sample), file(fastq) from ch_fastq_align

            output:
            set file(fasta), file(sizes), val(sample), file("*.sam") into ch_align_sam

            script:
            minimap_preset = (params.protocol == 'DNA') ? "-ax map-ont" : "-ax splice"
            kmer = (params.protocol == 'directRNA') ? "-k14" : ""
            stranded = (params.stranded || params.protocol == 'directRNA') ? "-uf" : ""
            """
            minimap2 $minimap_preset $kmer $stranded -t $task.cpus $index $fastq > ${sample}.sam
            """
        }

    } else if (params.aligner == 'graphmap') {

        process GraphMapAlign {
            tag "$sample"
            label 'process_medium'
            if (params.save_align_intermeds) {
                publishDir path: "${params.outdir}/${params.aligner}", mode: 'copy',
                    saveAs: { filename ->
                                  if (filename.endsWith(".sam")) filename
                            }
            }

            input:
            set file(fasta), file(index), file(sizes), val(sample), file(fastq) from ch_fastq_align

            output:
            set file(fasta), file(sizes), val(sample), file("*.sam") into ch_align_sam

            script:
            """
            graphmap align -t $task.cpus -r $fasta -i $index -d $fastq -o ${sample}.sam --extcigar
            """
        }
    }

    /*
     * STEP 9 - Coordinate sort BAM files
     */
    process SortBAM {
        tag "$sample"
        label 'process_medium'
        publishDir path: "${params.outdir}/${params.aligner}", mode: 'copy',
            saveAs: { filename ->
                          if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
                          else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
                          else if (filename.endsWith(".stats")) "samtools_stats/$filename"
                          else if (filename.endsWith(".sorted.bam")) filename
                          else if (filename.endsWith(".sorted.bam.bai")) filename
                          else null
                    }

        input:
        set file(fasta), file(sizes), val(sample), file(sam) from ch_align_sam

        output:
        set file(fasta), file(sizes), val(sample), file("*.sorted.{bam,bam.bai}") into ch_sortbam_bed12,
                                                                                       ch_sortbam_bedgraph
        file "*.{flagstat,idxstats,stats}" into ch_sortbam_stats_mqc

        script:
        """
        samtools view -b -h -O BAM -@ $task.cpus -o ${sample}.bam $sam
        samtools sort -@ $task.cpus -o ${sample}.sorted.bam -T $sample ${sample}.bam
        samtools index ${sample}.sorted.bam
        samtools flagstat ${sample}.sorted.bam > ${sample}.sorted.bam.flagstat
        samtools idxstats ${sample}.sorted.bam > ${sample}.sorted.bam.idxstats
        samtools stats ${sample}.sorted.bam > ${sample}.sorted.bam.stats
        """
    }

    /*
     * STEP 10 - Convert BAM to BEDGraph
     */
    process BAMToBedGraph {
        tag "$sample"
        label 'process_medium'

        when:
        !params.skip_alignment && !params.skip_bigwig
        input:
        set file(fasta), file(sizes), val(sample), file(bam) from ch_sortbam_bedgraph

        output:
        set file(fasta), file(sizes), val(sample), file("*.bedGraph") into ch_bedgraph
        file "*.version" into ch_bedtools_version

        script:
        """
        genomeCoverageBed -ibam ${bam[0]} -bg | sort -k1,1 -k2,2n >  ${sample}.bedGraph
        bedtools --version > bedtools.version
        """
    }

    /*
     * STEP 11 - Convert BEDGraph to BigWig
     */
    process BedGraphToBigWig {
        tag "$sample"
        label 'process_medium'
        publishDir path: "${params.outdir}/${params.aligner}/bigwig/", mode: 'copy',
            saveAs: { filename ->
                          if (filename.endsWith(".bigWig")) filename
                    }

        input:
        set file(fasta), file(sizes), val(sample), file(bedgraph) from ch_bedgraph

        output:
        set file(fasta), file(sizes), val(sample), file("*.bigWig") into ch_bigwig

        script:
        """
        bedGraphToBigWig $bedgraph $sizes ${sample}.bigWig
        """
    }

    /*
     * STEP 12 - Convert BAM to BED12
     */
    process BAMToBed12 {
        tag "$sample"
        label 'process_medium'

        when:
        !params.skip_bigbed
        input:
        set file(fasta), file(sizes), val(sample), file(bam) from ch_sortbam_bed12

        output:
        set file(fasta), file(sizes), val(sample), file("*.bed12") into ch_bed12

        script:
        """
        bedtools bamtobed -bed12 -cigar -i ${bam[0]} | sort -k1,1 -k2,2n > ${sample}.bed12
        """
    }

    /*
     * STEP 13 - Convert BED12 to BigBED
     */
    process Bed12ToBigBed {
        tag "$sample"
        label 'process_medium'
        publishDir path: "${params.outdir}/${params.aligner}/bigbed/", mode: 'copy',
            saveAs: { filename ->
                          if (filename.endsWith(".bb")) filename
                    }
        input:
        set file(fasta), file(sizes), val(sample), file(bed12) from ch_bed12

        output:
        set file(fasta), file(sizes), val(sample), file("*.bb") into ch_bigbed

        script:
        """
        bedToBigBed $bed12 $sizes ${sample}.bb
        """
    }
}

/*
 * STEP 14 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"
    file "*.version" into ch_rmarkdown_version

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    Rscript -e "library(markdown); write(x=as.character(packageVersion('markdown')), file='rmarkdown.version')"
    """
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    input:
    file guppy from ch_guppy_version.collect().ifEmpty([])
    file pycoqc from ch_pycoqc_version.collect().ifEmpty([])
    file nanoplot from ch_nanoplot_version.first()
    file fastqc from ch_fastqc_version.first()
    file samtools from ch_samtools_version.first().ifEmpty([])
    file minimap2 from ch_minimap2_version.first().ifEmpty([])
    file graphmap from ch_graphmap_version.first().ifEmpty([])
    file bedtools from ch_bedtools_version.first().ifEmpty([])
    file rmarkdown from ch_rmarkdown_version.collect()

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > pipeline.version
    echo $workflow.nextflow.version > nextflow.version
    multiqc --version &> multiqc.version
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-nanoseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/nanoseq Workflow Summary'
    section_href: 'https://github.com/nf-core/nanoseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * STEP 15 - MultiQC
 */
process MultiQC {
    publishDir "${params.outdir}/multiqc", mode: 'copy'

    when:
    !params.skip_multiqc

    input:
    file multiqc_config from ch_multiqc_config
    file ('samtools/*')  from ch_sortbam_stats_mqc.collect().ifEmpty([])
    file ('software_versions/*') from software_versions_yaml.collect()
    file ('workflow_summary/*') from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc . -f $rtitle $rfilename --config $multiqc_config -m custom_content -m samtools
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/nanoseq] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/nanoseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if (workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/nanoseq] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/nanoseq] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/nanoseq] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/nanoseq] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
        log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
        log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if (workflow.success) {
        log.info "${c_purple}[nf-core/nanoseq]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/nanoseq]${c_red} Pipeline completed with errors${c_reset}"
    }

}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/nanoseq v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
