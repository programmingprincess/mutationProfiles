#!/usr/bin/perl

use strict;
use warnings;

use feature qw/ say /;
use File::Basename;
use autodie;

use Data::Dumper;
use Data::Printer;

use vcfParse;

use Getopt::Long qw/ GetOptions /;


my $help;
my $vcf_file;
my $source = '';
my $out_dir = '.';

GetOptions( 'help'            =>    \$help,
            'vcf_in=s'        =>    \$vcf_file,
            'source=s'        =>    \$source,
            'out_dir=s'       =>    \$out_dir
          ) or die usage();

if ($help) { exit usage() }

if ( not $vcf_file or not $source ){
  say "Must privide an input file -v [input.vcf] and specify source -s [varscan|mutect]";
  exit usage();
}

my $filter_count = filter_vcf($vcf_file, $source, $out_dir);
# p(%$filter_count);

sub filter_vcf{
  my ($vcf_file, $source, $out_dir) = @_;

  my ( $data, $info_fields, $calls, $heads, $sams ) = vcfParse::parse($vcf_file);

  my (@headers) = @{$heads};
  my %calls = %{ $calls };
  my ($name, $extention) = split(/\.([^.]+)$/, basename($vcf_file), 2);
  my ($sample_name) = (split(/_/, $name))[0];

  my ($tumour_name, $normal_name) = @$sams;

  if ( $source eq 'varscan' or $source eq 'indel' ){
    ($tumour_name, $normal_name) = reverse @$sams;
  }
  elsif ($sample_name ne $tumour_name){
    die " [!] Processing sample with file name: $sample_name, and vcf tumour ID: $tumour_name";
  }

  if (scalar keys %calls == 0){
    die " [!] No variants found in file";
  }

  open my $out, '>', $out_dir . "/" . $sample_name . "_" . $source . "_filt.vcf";
  print $out "$_\n" for @headers;

  my (%filter_count, %filter_reasons);
  my $id_replacement = 0;

  for ( sort { @{ $data->{$a}}[0] cmp @{ $data->{$b}}[0] or
  		 @{ $data->{$a}}[1] <=> @{ $data->{$b}}[1] }  keys %{ $data } ){
    my ( $chrom, $pos, $id, $ref, $alt, $quality_score, $filt, $info_block, $format_block, $tumour_info_block, $normal_info_block, $samples ) = @{ $data->{$_} };

    my (@format) 		  = @{ $info_fields->{$_}[0] }; # The format field from VCF
  	my (%format_long)  = @{ $info_fields->{$_}[1] }; # The description of the FORMAT field (corresponding to ##FORMAT=<ID=[field] in header)
  	my (%info_long)    = @{ $info_fields->{$_}[2] }; # The description of the INFO field (corresponding to ##INFO=<ID=[field] in header)
  	my (@tumour_parts) = @{ $info_fields->{$_}[3] }; # The tumour values (for each FORMAT feild)
  	my (@normal_parts) = @{ $info_fields->{$_}[4] }; # The normal values (for each FORMAT feild)
  	my (%information)  = @{ $info_fields->{$_}[5] }; # The format field from VCF
  	my (%sample_info)  = @{ $info_fields->{$_}[6] }; # Per-sample info lookup (e.g. $sample_info{$_}{'[sample_name]'}{'[FORMAT_field]'})

    my $filter = 0;
    if ($id eq '.'){
      $id = $id_replacement++;
    }

    if ($chrom !~ /^(2L|2R|3L|3R|4|X|Y)$/ ){
      $filter++;
      $filter_count{'chrom'}++;
      push @{$filter_reasons{$id}}, 'chrom';
    }

    # Filter if alt AD < 2
    if ($sample_info{$_}{$tumour_name}{AD}){
      # Tumour alt and ref allele depths
      my ($t_ref_ad, $t_alt_ad);
      # Normal alt and ref allele depths
      my ($n_ref_ad, $n_alt_ad );

      if ($source eq 'mutect'){
        my ($tumour_name, $normal_name) = @$sams;
        ($t_ref_ad, $t_alt_ad) = split(/,/, $sample_info{$_}{$tumour_name}{AD});
        ($n_ref_ad, $n_alt_ad) = split(/,/, $sample_info{$_}{$normal_name}{AD});
        # $t_alt_ad = 3; # Force mutect2 vars through...
      }
      elsif ($source eq 'varscan' or $source eq 'indel'){
        $t_alt_ad  = $sample_info{$_}{$tumour_name}{AD};
        $t_ref_ad  = $sample_info{$_}{$tumour_name}{RD};
        $n_alt_ad  = $sample_info{$_}{$normal_name}{AD};
        $n_ref_ad  = $sample_info{$_}{$normal_name}{RD};
        # should reduce to p <= 0.01
        if ($information{$_}{SPV} >= 0.05){
          $filter_count{'p-val'}++;
          push @{$filter_reasons{$id}}, 'p-val';
          $filter++;
        }
      }

      if ($t_alt_ad < 2){
        $filter_count{'alt-allele-depth'}++;
        push @{$filter_reasons{$id}}, 'alt-allele-depth';
        $filter++;
      }

      # Filter if alt AD + ref AD < 5
      if ($t_alt_ad + $t_ref_ad < 5){
        $filter_count{'depth'}++;
        push @{$filter_reasons{$id}}, 'depth';
        my $sample_depth = $t_alt_ad + $t_ref_ad;
        $filter++;
      }

      # Filter if normal alt AD != 0
      if ($n_alt_ad != 0){
        $filter_count{'normal-has-alt-allele'}++;
        push @{$filter_reasons{$id}}, 'normal-has-alt-allele';
        $filter++;
      }
      # print "$chrom:$pos, $tumour_name\_alt_depth: $t_alt_ad, $tumour_name\_ref_depth: $t_ref_ad, $normal_name\_alt_depth: $n_alt_ad, $normal_name\_ref_depth: $n_ref_ad\t||\t";
      # print join(",", @{$filter_reasons{$id}} ) . "\n";
     }

     if ($sample_info{$_}{$tumour_name}{AF}){
       my $af = $sample_info{$_}{$tumour_name}{AF};
     }

     if ( $filter == 0){
       print $out "$calls{$_}\n";
     }
   }
  return(\%filter_reasons);
 }





 sub usage {
   print
 "
 usage: perl vcfFilter.pl [-h] [-v] [-s]

 vcfFilter
 author: Nick Riddiford (nick.riddiford\@curie.fr)
 version: v0.1
 description: Filter SNV calls using vcfParser

 arguments:
   -h, --help            show this help message and exit
   -v, --vcf_file        input .vcf file
   -s, --source          source type (e.g. 'Mutect2') - will be appended to output file name
   -o, --out_dir         output directory [Default = cwd]
 "
 }







#
#
# my $vcf_file = shift;
#
# my ($snvs, $info, $filtered_data) = parse($vcf_file);
#
# my ($name, $extention) = split(/\.([^.]+)$/, basename($vcf_file), 2);
#
# my ($id) = (split(/_/, $name))[0];
#
# open my $out, '>', $id . "_mutect_filtered.snv.vcf";
#
# my %filtered_snvs = %{ $filtered_data };
# my $sv_count = 0;
#
# for (sort {$a <=> $b} keys %filtered_snvs){
#   my $line = $filtered_snvs{$_};
#
#   if ($line =~ /^#/){
#     print $out $line . "\n";
#   }
#   else {
#     $sv_count++;
#     my @cols = split("\t", $line);
#     print $out join("\t", @cols[0..5], "PASS", @cols[7..$#cols]) . "\n";
#   }
# }
#
# say "$sv_count snvs in $id";
#
# sub parse {
#   my $file = shift;
#   open my $in, '<', $file or die $!;
#
#   my @headers;
#
#   my (%snvs, %info, %filtered_snvs);
#   my ($tumour_name, $control_name);
#   my %format_long;
#   my %info_long;
#   my $filter_count;
#   my @samples;
#   my $replacement_id = 1;
#
#   while(<$in>){
#     chomp;
#
#     if (/^#{2}/){
#        push @headers, $_;
#       $filtered_snvs{$.} = $_;
#
#       if (/##FORMAT/){
#
#         my ($format_long) = $_ =~ /\"(.*?)\"/;
#         my ($available_format_info) = $_ =~ /ID=(.*?),/;
#         $format_long{$available_format_info} = $format_long;
#       }
#
#       if (/##INFO/) {
#         my ($info_long) = $_ =~ /\"(.*?)\"/;
#         my ($available_info) = $_ =~ /ID=(.*?),/;
#         $info_long{$available_info} = $info_long;
#       }
#       next;
#     }
#
#     if (/^#{1}/){
#        push @headers, $_;
#       $filtered_snvs{$.} = $_;
#       my @split = split;
#       push @samples, $_ foreach @split[9..$#split];
#
#       $control_name = $samples[0];
#       $tumour_name = $samples[1];
#       next;
#     }
#
#     my @fields = split;
#
#     my ($chr, $pos, $id, $ref, $alt, $quality_score, $filt, $info_block, $format_block, @sample_info) = @fields;
#
#     if ( $id eq '.' ){
#       $id = $replacement_id++;
#     }
#
#     my %sample_parts;
#
#     push @{$sample_parts{$samples[$_]}}, split(/:/, $sample_info[$_]) for 0..$#samples;
#
#     my @normal_parts   = split(/:/, $sample_info[0]);
#     my @tumour_parts   = split(/:/, $sample_info[1]);
#
#     my @format        = split(/:/, $format_block);
#     my @info_parts    = split(/;/, $info_block);
#
#     my %sample_info;
#
#     for my $sample (@samples){
#       for my $info (0..$#format){
#         $sample_info{$id}{$sample}{$format[$info]} = $sample_parts{$sample}[$info];
#       }
#     }
#
#     my @filter_reasons;
#
#     #######################
#     # Allele depth filter #
#     #######################
#
#     # Filter if alt AD < 2
#     if ($sample_info{$id}{'TUMOR'}{'AD'}){
#       my ($t_ref_ad, $t_alt_ad) = split(/,/, $sample_info{$id}{'TUMOR'}{'AD'});
#       if ($t_alt_ad < 2){
#         # say "Alt allele depth filt: $t_alt_ad";
#         push @filter_reasons, "alt\_AD=" . $sample_info{$id}{'TUMOR'}{'AD'};
#       }
#
#       # Filter if alt AD + ref AD < 5
#       if ($t_alt_ad + $t_ref_ad < 5){
#         my $sample_depth = $t_alt_ad + $t_ref_ad;
#         # say "Sample depth filt: $sample_depth";
#         push @filter_reasons, "AD=" . $sample_depth;
#       }
#       # Filter if normal alt AD != 0
#       my ($n_ref_ad, $n_alt_ad ) = split(/,/, $sample_info{$id}{'NORMAL'}{'AD'});
#       if ($n_alt_ad != 0){
#         # say "Normal alt allele depth filt: $n_alt_ad";
#         push @filter_reasons, "NORM_alt_AD=" . $n_alt_ad;
#       }
#     }
#
#     if ($sample_info{$id}{'TUMOR'}{'AF'}){
#       my $af = $sample_info{$id}{'TUMOR'}{'AF'};
#       if ($af < 0.075){
#         # say "Allele freq filt: $af";
#         push @filter_reasons, "TUM\_AF=" . $sample_info{$id}{'TUMOR'}{'AF'};
#       }
#     }
#
#     my %information;
#
#     foreach(@info_parts){
#
#       my ($info_key, $info_value);
#
#       if (/=/){
#         ($info_key, $info_value) = $_ =~ /(.*)=(.*)/;
#       }
#
#       else {
#         ($info_key) = $_ =~ /(.*)/;
#         $info_value = "TRUE";
#       }
#       $information{$id}{$info_key} = $info_value;
#     }
#
#     $snvs{$id} = [ @fields[0..10], \@filter_reasons, \@samples ];
#
#     $info{$id} = [ [@format], [%format_long], [%info_long], [@tumour_parts], [@normal_parts], [%information], [%sample_info] ];
#
#     if ( scalar @filter_reasons == 0 ){
#       $filtered_snvs{$.} = $_;
#     }
#
#   }
#
#   return (\%snvs, \%info, \%filtered_snvs);
# }
