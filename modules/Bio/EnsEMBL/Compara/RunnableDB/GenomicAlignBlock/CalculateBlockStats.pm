=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2019] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::GenomicAlignBlock::CalculateBlockStats

=head1 DESCRIPTION

Will generate statistics for a list of alignment blocks. The computation is
offloaded to Utils::Cigars, and this Runnable only has to sum up the statistics.

Two statistics are computed:
1. The alignment depth, i.e. the number of sequences aligned to a given sequence,
2. The pairwise coverage
They are then dataflown to the branches 2 and 3 (alignment depth) and 4
(pairwise coverage)

=cut

package Bio::EnsEMBL::Compara::RunnableDB::GenomicAlignBlock::CalculateBlockStats;

use strict;
use warnings;

use Bio::EnsEMBL::Compara::Utils::Cigars;
use Bio::EnsEMBL::Compara::Utils::Preloader;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');


sub run {
    my $self = shift @_;

    $self->param('depth_by_genome', {});
    $self->param('total_pairwise_coverage', {});

    # _range_list is the name used by eHive's JobFactory
    # the list contains genomic_align_block_ids
    foreach my $genomic_align_block_id (@{$self->param_required('_range_list')}) {
        $self->process_one_block($genomic_align_block_id);
    }
}


sub process_one_block {
    my $self = shift @_;
    my $genomic_align_block_id = shift @_;

    # Load from the database
    my $genomic_align_block = $self->compara_dba->get_GenomicAlignBlockAdaptor->fetch_by_dbID($genomic_align_block_id);
    my $genomic_aligns      = $genomic_align_block->genomic_align_array();

    Bio::EnsEMBL::Compara::Utils::Preloader::load_all_DnaFrags($self->compara_dba->get_DnaFragAdaptor, $genomic_aligns);

    $self->disconnect_from_databases;

    # Convert the cigar strings to arrays beforehand and just once
    my @all_cigar_arrays;
    my @all_genome_db_ids;
    while(my $ga = shift @$genomic_aligns) {
        push @all_cigar_arrays,  Bio::EnsEMBL::Compara::Utils::Cigars::get_cigar_array($ga->cigar_line);
        push @all_genome_db_ids, $ga->dnafrag->genome_db_id;
    }

    my $total_pairwise_coverage = $self->param('total_pairwise_coverage');
    my $pairwise_coverage = Bio::EnsEMBL::Compara::Utils::Cigars::calculate_pairwise_coverage(\@all_cigar_arrays, \@all_genome_db_ids);
    foreach my $gdb1 (keys %$pairwise_coverage) {
        foreach my $gdb2 (keys %{$pairwise_coverage->{$gdb1}}) {
            $total_pairwise_coverage->{$gdb1}->{$gdb2} += $pairwise_coverage->{$gdb1}->{$gdb2};
        }
    }

    my $depth_by_genome = $self->param('depth_by_genome');
    my $depths = Bio::EnsEMBL::Compara::Utils::Cigars::compute_alignment_depth(\@all_cigar_arrays, \@all_genome_db_ids);
    foreach my $genome_db_id ( keys %$depths ) {
        foreach my $key (qw(n_aligned_pos n_total_pos depth_sum)) {
            $depth_by_genome->{$genome_db_id}->{$key} += $depths->{$genome_db_id}->{$key};
        }
        foreach my $d (keys %{$depths->{$genome_db_id}->{'depth_breakdown'}}) {
            $depth_by_genome->{$genome_db_id}->{'breakdown'}->{$d} += $depths->{$genome_db_id}->{'depth_breakdown'}->{$d};
        }
    }
}

sub write_output {
    my $self = shift @_;

    my $depth_by_genome = $self->param('depth_by_genome');
    foreach my $genome_db_id ( keys %$depth_by_genome ) {
        $self->dataflow_output_id({
                'genome_db_id'                  => $genome_db_id,
                'num_of_positions'              => $depth_by_genome->{$genome_db_id}->{'n_total_pos'},
                'num_of_aligned_positions'      => $depth_by_genome->{$genome_db_id}->{'n_aligned_pos'},
                'num_of_other_seq_positions'    => $depth_by_genome->{$genome_db_id}->{'depth_sum'},
            }, 2);
        foreach my $d (keys %{$depth_by_genome->{$genome_db_id}->{'breakdown'}}) {
            $self->dataflow_output_id({
                    'genome_db_id'      => $genome_db_id,
                    'depth'             => $d,
                    'num_of_positions'  => $depth_by_genome->{$genome_db_id}->{'breakdown'}->{$d},
                }, 3);
        }
    }

    my $pairwise_coverage = $self->param('total_pairwise_coverage');
    foreach my $gdb1 ( keys %$pairwise_coverage ) {
        foreach my $gdb2 ( keys %{$pairwise_coverage->{$gdb1}} ) {
            $self->dataflow_output_id({
                    'from_genome_db_id'         => $gdb1,
                    'to_genome_db_id'           => $gdb2,
                    'num_of_aligned_positions'  => $pairwise_coverage->{$gdb1}->{$gdb2},
                }, 4);
        }
    }
}

1;
