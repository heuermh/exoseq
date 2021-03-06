#!/usr/bin/env nextflow
/*
========================================================================================
               nf-core E X O S E Q    B E S T    P R A C T I C E
========================================================================================
 #### Homepage / Documentation
 https://github.com/nf-core/ExoSeq
 #### Authors
 Senthilkumar Panneerselvam @senthil10 <senthilkumar.panneerselvam@scilifelab.se>
 Phil Ewels @ewels <phil.ewels@scilifelab.se>
 Alex Peltzer @alex_peltzer <alexander.peltzer@qbic.uni-tuebingen.de>
 Marie Gauder <marie.gauder@student.uni-tuebingen.de>
----------------------------------------------------------------------------------------
Developed based on GATK's best practise, takes set of FASTQ files and performs:
 - alignment (BWA)
 - recalibration (GATK)
 - realignment (GATK)
 - variant calling (GATK)
 - variant evaluation (SnpEff)
*/

// Package version
version = '0.8.1'

// Help message
helpMessage = """
===============================================================================
nf-core/ExoSeq : Exome/Targeted sequence capture best practice analysis v${version}
===============================================================================

Usage: nextflow nf-core/ExoSeq --reads '*_R{1,2}.fastq.gz' --genome GRCh37

This is a typical usage where the required parameters (with no defaults) were
given. The available paramaters are listed below based on category

Required parameters:
--reads                        Absolute path to project directory
--genome                       Name of iGenomes reference


Output:
--outdir                       Path where the results to be saved [Default: './results']

Kit files:
--kit                          Kit used to prep samples [Default: 'agilent_v5']
--bait                         Absolute path to bait file
--target                       Absolute path to target file
--target_bed                   Absolute path to target bed file (snpEff compatible format)

Genome/Variation files:
--dbsnp                        Absolute path to dbsnp file
--thousandg                    Absolute path to 1000G file
--mills                        Absolute path to Mills file
--omni                         Absolute path to Omni file
--gfasta                       Absolute path to genome fasta file
--bwa_index                    Absolute path to bwa genome index

Other options:
--exome                        Exome data, if this is not set, run as genome data
--project                      Uppnex project to user for SLURM executor

For more detailed information regarding the parameters and usage refer to package
documentation at https:// github.com/nf-core/ExoSeq
"""

// Variables and defaults
params.name = false
params.help = false
params.reads = false
params.singleEnd = false
params.genome = false
params.run_id = false
params.exome = false //default genome, set to true to run restricting to exome positions
params.aligner = 'bwa' //Default, but stay tuned for later ;-) 
params.saveReference = true


// Output configuration
params.outdir = './results'
params.saveAlignedIntermediates = false
params.saveIntermediateVariants = false


// Clipping options
params.notrim = false
params.clip_r1 = 0
params.clip_r2 = 0
params.three_prime_clip_r1 = 0
params.three_prime_clip_r2 = 0

// Kit options
params.kit = 'agilent_v5'
params.bait = params.kitFiles[ params.kit ] ? params.kitFiles[ params.kit ].bait ?: false : false
params.target = params.kitFiles[ params.kit ] ? params.kitFiles[ params.kit ].target ?: false : false
params.target_bed = params.kitFiles[ params.kit ] ? params.kitFiles[ params.kit ].target_bed ?: false : false
params.dbsnp = params.metaFiles[ params.genome ] ? params.metaFiles[ params.genome ].dbsnp ?: false : false
params.thousandg = params.metaFiles[ params.genome ] ? params.metaFiles[ params.genome ].thousandg ?: false : false
params.mills = params.metaFiles[ params.genome ] ? params.metaFiles[ params.genome ].mills ?: false : false
params.omni = params.metaFiles[ params.genome ] ? params.metaFiles[ params.genome ].omni ?: false : false
params.gfasta = params.metaFiles[ params.genome ] ? params.metaFiles[ params.genome ].gfasta ?: false : false
params.bwa_index = params.metaFiles[ params.genome ] ? params.metaFiles[ params.genome ].bwa_index ?: false : false
params.multiqc_config = "$baseDir/conf/multiqc_config.yaml"

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


// Show help when needed
if (params.help){
    log.info helpMessage
    exit 0
}

// Check blocks for certain required parameters, to see they are given and exist
if (!params.reads || !params.genome){
    exit 1, "Parameters '--reads' and '--genome' are required to run the pipeline"
}
if (!params.kitFiles[ params.kit ] && ['bait', 'target'].count{ params[it] } != 2){
    exit 1, "Kit '${params.kit}' is not available in pre-defined config, so " +
            "provide all kit specific files with option '--bait' and '--target'"
}
 if (!params.metaFiles[ params.genome ] && ['gfasta', 'bwa_index', 'dbsnp', 'thousandg', 'mills', 'omni'].count{ params[it] } != 6){
     exit 1, "Genome '${params.genome}' is not available in pre-defined config, so you need to provide all genome specific " +
             "files with options '--gfasta', '--bwa_index', '--dbsnp', '--thousandg', '--mills' and '--omni'"
 }

// Create a channel for input files

Channel
    .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
    .into { read_files_fastqc; read_files_trimming }


// Validate Input indices for BWA Mem and GATK

if(params.aligner == 'bwa' ){
    bwaId = Channel
        .fromPath("${params.gfasta}.bwt")
        .ifEmpty { exit 1, "BWA index not found: ${params.gfasta}.bwt" }
}

// Set up input channels for certain files (if required)

multiqc_config = file(params.multiqc_config)

// Create a summary for the logfile
def summary = [:]
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.reads
summary['Data Type']    = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Genome']       = params.genome
summary['WES/WGS']      = params.exome ? 'WES' : 'WGS'
summary['Trim R1'] = params.clip_r1
summary['Trim R2'] = params.clip_r2
summary["Trim 3' R1"] = params.three_prime_clip_r1
summary["Trim 3' R2"] = params.three_prime_clip_r2
if(params.aligner == 'bwa'){
    summary['Aligner'] = "BWA Mem"
    if(params.bwa_index)          summary['BWA Index']   = params.bwa_index
    else if(params.gfasta)          summary['Fasta Ref']    = params.gfasta
}
summary['Save Intermediate Aligned Files'] = params.saveAlignedIntermediates ? 'Yes' : 'No'
summary['Save Intermediate Variant Files'] = params.saveIntermediateVariants ? 'Yes' : 'No'
summary['Max Memory']     = params.max_memory
summary['Max CPUs']       = params.max_cpus
summary['Max Time']       = params.max_time
summary['Output dir']     = params.outdir
summary['Working dir']    = workflow.workDir
summary['Container']      = workflow.container
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


// Nextflow version check
nf_required_version = '0.25.0'
try {
    if( ! workflow.nextflow.version.matches(">= $nf_required_version") ){
        throw GroovyException('Nextflow version too old')
        }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please run `nextflow self-update` to update Nextflow.\n" +
              "============================================================"
}


//TODO: We need to specify input channels in a separate step. This is solely a start and a result of splitting both files to two separate scripts.


/*
 * Step 9 - Genotype generate GVCFs using GATK's GenotypeGVCFs
 * 
*/ 

process genotypegvcfs{
    tag "${name}"
    publishDir "${params.outdir}/GATK_GenotypeGVCFs/", mode: 'copy', 
    saveAs: {filename -> params.saveIntermediateVariants ? "$filename" : null }

    input:
    set val(name), file(raw_vcf), file(raw_vcf_idx) from raw_variants

    output:
    set val(name), file("${name}_gvcf.vcf"), file("${name}_gvcf.vcf.idx") into raw_gvcfs

    script:
    """
    gatk -T GenotypeGVCFs \\
    -R $params.gfasta \\
    --variant $raw_vcf \\
    -nt $task.cpus \\
    -o ${name}_gvcf.vcf \\
    """
}

/*
 * Step 10 - Create separate files for SNPs and Indels 
 * 
*/ 

process variantSelect {
    tag "${name}"
    publishDir "${params.outdir}/GATK_VariantSelection", mode: 'copy', 
    saveAs: {filename -> params.saveIntermediateVariants ? "$filename" : null }

    input:
    set val(name), file(raw_vcf), file(raw_vcf_idx) from raw_gvcfs

    output:
    set val(name), file("${name}_snp.vcf"), file("${name}_snp.vcf.idx") into raw_snp
    set val(name), file("${name}_indels.vcf"), file("${name}_indels.vcf.idx") into raw_indels

    script:
    """
    gatk -T SelectVariants \\
        -R $params.gfasta \\
        --variant $raw_vcf \\
        --out ${name}_snp.vcf \\
        --selectTypeToInclude SNP

    gatk -T SelectVariants \\
        -R $params.gfasta \\
        --variant $raw_vcf \\
        --out ${name}_indels.vcf \\
        --selectTypeToInclude INDEL \\
        --selectTypeToInclude MIXED \\
        --selectTypeToInclude MNP \\
        --selectTypeToInclude SYMBOLIC \\
        --selectTypeToInclude NO_VARIATION
    """
}


/*
 * Step 11 - Recalibrate SNPs using Omni, 1000G and DBSNP databases 
 * 
*/ 

process recalSNPs {
    tag "${name}"
    publishDir "${params.outdir}/GATK_RecalibrateSNPs/", mode: 'copy', 
    saveAs: {filename -> params.saveIntermediateVariants ? "$filename" : null }

    input:
    set val(name), file(raw_snp), file(raw_snp_idx) from raw_snp

    output:
    set val(name), file("${sample}_filtered_snp.vcf"), file("${sample}_filtered_snp.vcf.idx") into filtered_snp

    script:
    """
    gatk -T VariantRecalibrator \\
        -R $params.gfasta \\
        --input $raw_snp \\
        --maxGaussians 4 \\
        --recal_file ${name}_snp.recal \\
        --tranches_file ${name}_snp.tranches \\
        -resource:omni,known=false,training=true,truth=true,prior=12.0 $params.omni \\
        -resource:1000G,known=false,training=true,truth=false,prior=10.0 $params.thousandg \\
        -resource:dbsnp,known=true,training=false,truth=false,prior=2.0 $params.dbsnp \\
        --mode SNP \\
        -an QD \\
        -an FS \\
        -an MQ

    gatk -T ApplyRecalibration \\
        -R $params.gfasta \\
        --out ${name}_filtered_snp.vcf \\
        --input $raw_snp \\
        --mode SNP \\
        --tranches_file ${name}_snp.tranches \\
        --recal_file ${name}_snp.recal \\
        --ts_filter_level 99.5 \\
        -mode SNP 
    """
}


/*
 * Step 12 - Recalibrate INDELS using the Mills golden dataset 
 * 
*/ 

process recalIndels {
    tag "${name}"
    publishDir "${params.outdir}/GATK_RecalibrateIndels", mode: 'copy', 
    saveAs: {filename -> params.saveIntermediateVariants ? "$filename" : null }

    input:
    set val(name), file(raw_indel), file(raw_indel_idx) from raw_indels

    output:
    set val(name), file("${name}_filtered_indels.vcf"), file("${name}_filtered_indels.vcf.idx") into filtered_indels

    script:
    """
    gatk -T VariantRecalibrator \\
        -R $params.gfasta \\
        --input $raw_indel \\
        --maxGaussians 4 \\
        --recal_file ${name}_indel.recal \\
        --tranches_file ${name}_indel.tranches \\
        -resource:mills,known=false,training=true,truth=true,prior=12.0 $params.mills \\
        -resource:dbsnp,known=true,training=false,truth=false,prior=2.0 $params.dbsnp \\
        -an QD -an DP -an FS -an SOR \\
        -mode INDEL 

    gatk -T ApplyRecalibration \\
        -R $params.gfasta \\
        --out ${name}_filtered_indels.vcf \\
        --input $raw_indel \\
        --mode SNP \\
        --tranches_file ${name}_indel.tranches \\
        --recal_file ${name}_indel.recal \\
        --ts_filter_level 99.0 \\
        -mode INDEL
    """
}

/*
 * Step 13 - Combine recalibrated files again
 * 
*/ 

filtered_snp
    .cross(filtered_indels)
    .map{ it -> [it[0][0], it[0][1], it[0][2], it[1][1], it[1][2]] }
    .set{ variants_filtered }

/*
 * Step 14 - Combine recalibrated files again using GATK's CombineVariants
 * 
*/

process combineVariants {
    tag "$name"
    publishDir "${params.outdir}/GATK_CombineVariants/", mode: 'copy', 
    saveAs: {filename -> params.saveIntermediateVariants ? "$filename" : null }

    input:
    set file(fsnp), file(fsnp_idx), file(findel), file(findel_idx) from variants_filtered

    output:
    set file("${name}_combined_variants.vcf"), file("${name}_combined_variants.vcf.idx") into (combined_variants_evaluate,combined_variants_snpEff, combined_variants_gatk)

    script:
    """
    gatk -T CombineVariants \\
        -R $params.gfasta \\
        --out ${name}_combined_variants.vcf \\
        --genotypemergeoption PRIORITIZE \\
        --variant:${name}_SNP_filtered $fsnp \\
        --variant:${name}_indels_filtered $findel \\
        --rod_priority_list ${name}_SNP_filtered,${name}_indels_filtered
    """
}

/*
 * Step 15 - Annotate Variants with SNPEff
 * 
*/
process variantAnnotatesnpEff {
    tag "$name"
    publishDir "${params.outdir}/SNPEFF_AnnotatedVariants/", mode: 'copy', 
    saveAs: {filename -> params.saveIntermediateVariants ? "$filename" : null }

    input:
    set file(phased_vcf), file(phased_vcf_ind) from combined_variants_snpEff

    output:
    file "*.{snpeff}" into combined_variants_gatk_snpeff
    file '.command.log' into snpeff_stdout
    file 'SnpEffStats.csv' into snpeff_results

    script:
    """
        snpEff \\
        -c /usr/local/lib/snpEff/snpEff.config \\
        -i vcf \\
        -csvStats SnpEffStats.csv \\
        -o gatk \\
        -o vcf \\
        -filterInterval $params.target_bed GRCh37.75 $phased_vcf \\
            > ${name}_combined_phased_variants.snpeff 
        
        # Print version number to standard out
        echo "GATK version "\$(snpEff -version 2>&1)
    """
}


/*
 * Step 16 - Annotate Variants with GATK
 * 
*/

process variantAnnotateGATK{     
    tag "$name"
    publishDir "${params.outdir}/GATK_AnnotatedVariants", mode: 'copy'

    input:
    set file(phased_vcf), file(phased_vcf_ind) from combined_variants_gatk
    file(phased_vcf_snpeff) from combined_variants_gatk_snpeff

    output:
    file "*.{vcd,idx}"

    script:
    """
    gatk -T VariantAnnotator \\
        -R $params.gfasta \\
        -A SnpEff \\
        --variant $phased_vcf \\
        --snpEffFile ${name}_combined_phased_variants.snpeff \\
        --out ${name}_combined_phased_annotated_variants.vcf
    """
}



/*
 * Step 17 - Perform variant evaluation with GATK's VariantEval tool
*/

process variantEvaluate {
    tag "$name"
    publishDir "${params.outdir}/GATK_VariantEvaluate", mode: 'copy'

    input:
    set file("${name}_combined_variants.vcf"), file("${name}_combined_variants.vcf.idx") from combined_variants_evaluate

    output:
    file "${name}_combined_phased_variants.eval"
    file "${name}_combined_phased_variants.eval" into gatk_variant_eval_results

    script:
    """
    gatk -T VariantEval \\
        -R $params.gfasta \\
        --eval $phased_vcf \\
        --dbsnp $params.dbsnp \\
        -o ${name}_combined_phased_variants.eval \\
        -L $params.target \\
        --doNotUseAllStandardModules \\
        --evalModule TiTvVariantEvaluator \\
        --evalModule CountVariants \\
        --evalModule CompOverlap \\
        --evalModule ValidationReport \\
        --stratificationModule Filter \\
        -l INFO
    """
}


/*
 * Step 18 - Generate Software Versions Map
 * 
*/
software_versions = [
  'FastQC': null, 'Trim Galore!': null, 'BWA': null, 'Picard MarkDuplicates': null, 'GATK': null,
  'SNPEff': null, 'QualiMap': null, 'Nextflow': "v$workflow.nextflow.version"
]

/*
* Step 19 - Generate a YAML file for software versions in the pipeline
* This is then parsed by MultiQC and the report feature to produce a final report with the software Versions in the pipeline.
*/ 

process get_software_versions {
    cache false
    executor 'local'

    input:
    val fastqc from fastqc_stdout.collect()
    val trim_galore from trimgalore_logs.collect()
    val bwa from bwa_stdout.collect()
    val markDuplicates from markDuplicates_stdout.collect()
    val gatk from gatk_stdout.collect()
    val qualimap from qualimap_stdout.collect()
    val snpeff from snpeff_stdout.collect()

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml

    exec:
    software_versions['FastQC'] = fastqc[0].getText().find(/FastQC v(\S+)/) { match, version -> "v$version"}
    software_versions['Trim Galore!'] = trim_galore[0].getText().find(/Trim Galore version: (\S+)/) {match, version -> "v$version"}
    software_versions['BWA'] = bwa[0].getText().find(/Version: (\S+)/) {match, version -> "v$version"}
    software_versions['Picard MarkDuplicates'] = markDuplicates[0].getText().find(/Picard version ([\d\.]+)/) {match, version -> "v$version"}
    software_versions['GATK'] = gatk[0].getText().find(/GATK version ([\d\.]+)/) {match, version -> "v$version"} 
    software_versions['QualiMap'] = qualimap[0].getText().find(/QualiMap v.(\S+)/) {match, version -> "v$version"}
    software_versions['SNPEff'] = snpeff[0].getText().find(/SnpEff (\S+)/) {match, version -> "v$version" }

    def sw_yaml_file = task.workDir.resolve('software_versions_mqc.yaml')
    sw_yaml_file.text  = """
    id: 'nf-core/ExoSeq'
    section_name: 'nf-core/ExoSeq Software Versions'
    section_href: 'https://github.com/nf-core/ExoSeq'
    plot_type: 'html'
    description: 'are collected at run time from the software output.'
    data: |
        <dl class=\"dl-horizontal\">
${software_versions.collect{ k,v -> "            <dt>$k</dt><dd>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</dd>" }.join("\n")}
        </dl>
    """.stripIndent()
}


/*
* Step 20 - Collect metrics, stats and other resources with MultiQC in a single call
*/ 

process multiqc {
    tag "$name"
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config
    file (fastqc:'fastqc/*') from fastqc_results.collect()
    file ('trimgalore/*') from trimgalore_results.collect()
    file ('picard/*') from markdup_results.collect()
    file ('snpEff/*') from snpeff_results.collect()
    file ('gatk_base_recalibration/*') from gatk_base_recalibration_results.collect()
    file ('gatk_variant_eval/*') from gatk_variant_eval_results.collect()
    file ('qualimap/*') from qualimap_results.collect()
    file ('software_versions/*') from software_versions_yaml.collect()


    output:
    file '*multiqc_report.html' into multiqc_report
    file '*_data' into multiqc_data
    file '.command.err' into multiqc_stderr
    val prefix into multiqc_prefix

    script:
    prefix = fastqc[0].toString() - '_fastqc.html' - 'fastqc/'
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config . 2>&1
    """

}

