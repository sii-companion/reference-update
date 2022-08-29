#!/usr/bin/env nextflow
nextflow.enable.dsl=1


process get_reference_species {
    conda 'environment.yml'
    
    output:
      stdout species_ch

    """
    IFS=\$'\\n'; ${params.EUPATHWS_SCRIPTS_PATH}/get_reference_species -l ${params.veupathdb_username}:${params.veupathdb_password} ${params.veupathdb_domain}
    """
}

species_ch.splitText().map{it -> it.trim()}.set { org }
process get_organism {
    conda 'environment.yml'
    publishDir "${params.REFERENCE_PATH}", mode: 'copy'

    input:
      val org

    output:
      path 'clean_gff/*.gff3' into org_gff3
      path '*_Proteins.fasta' into org_prot_fasta
      path '*_Genome.fasta' into org_fasta
      path '*.gaf' into org_gaf
      stdout org_ch
      
    """
    ${params.EUPATHWS_SCRIPTS_PATH}/get_organism -l ${params.veupathdb_username}:${params.veupathdb_password} ${params.veupathdb_domain} \"${org}\"
    rename "s/ /_/g"  *
    mkdir clean_gff
    for x in *.gff3 ; do gt gff3 -sort -retainids -tidy \$x > clean_gff/\$x & done
    ls *.gff3 | sed 's/.gff3//g'
    """
}

if (params.do_augustus) {
  org_ch.splitText().map{it -> it.trim()}.set { org } 
  process train_augustus {
      input:
        val x from org
        path "${x}.gff3" from org_gff3
        path "${x}_Genome.fasta" from org_fasta
      
      output:
        path "${x}.gff3" into gff3_out

      """
      ${params.AUGUSTUS_SCRIPTS_PATH}/new_species.pl --species=${x} --ignore
      ${params.AUGUSTUS_SCRIPTS_PATH}/gff2gbSmallDNA.pl ${x}.gff3 ${x}_Genome.fasta 1000 sampled.gb
      ${params.AUGUSTUS_BIN_PATH}/etraining --species=${x} sampled.gb
      """
  }
} else {
  org_gff3.set { gff3_out }
}

process prepare_references {
    publishDir "${params.REFERENCE_PATH}", mode: 'copy'

    input:
      path "*" from gff3_out.collect()

    output:
      path "Reference/references-in.json" into references_in
      
    """
    for x in *.gff3; do python ${baseDir}/parse_chromosomes.py \$x; done > ChromosomeFile.txt
    mkdir -p Reference
    ls *gff3 | perl ${baseDir}/generateReferences-i.json.pl ${params.REFERENCE_PATH} ${params.veupathdb_group} ${params.AUGUSTUS_CONFIG_PATH} > Reference/references-in.json    
    """
}

// TODO make update_references.lua internal to this package and allow it to run in parallel for each species
process update_references{
    debug true
    publishDir "${params.REFERENCE_PATH}/Reference", mode: 'copy'

    input:
      path references_in
    
    output:
      path "*", type: "dir"
      path "references.json"
      path "*/proteins.fasta" into prots

    """
    ${params.COMPANION_BIN_PATH}/update_references.lua
    """
}

if (params.do_orthomcl) {
  // TODO cite https://bdataanalytics.biomedcentral.com/articles/10.1186/s41044-016-0019-8
  process run_porthomcl {
      conda 'python=2.7'
      cpus params.porthomcl_threads
      debug true
      publishDir "${params.REFERENCE_PATH}/Reference/_all", mode: 'copy'

      input:
        path "0.input_faa/proteins*.fasta" from prots
      
      output:
        path "all_orthomcl.out"

      """
      ${params.PORTHOMCL_PATH}/porthomcl.sh -t ${task.cpus} .
      ${params.PORTHOMCL_PATH}/orthomclMclToGroups ORTHOMCL 0 < 8.all.ort.group > all_orthomcl.out
      """
  }
}