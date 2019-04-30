#!/usr/bin/env perl
use strict;
use warnings;
use Cwd "abs_path";
use File::Path qw[remove_tree];
use JSON;
# # # # # CONFIG
my $BASE_DIR    = abs_path(__FILE__."/../..");
my $APP_DIR     = "$BASE_DIR/app";
my $LAMBDA_DIR  = "$BASE_DIR/lambda";
my $MODELS_DIR  = "$BASE_DIR/models";
my @REGIONS     = undef;
my @LOCALES     = undef;
my $JSON        = JSON->new->pretty;
my %BUILD_TOOL;
my @BUILD_TOOLS = (
    {
        name            => 'gradle',
        build_file      => 'build.gradle',
        build_commands  => ['gradle createLambda'],
        flavours        => [
            {
                name        => 'wrapper',
                if          => sub { -f "$APP_DIR/gradlew" },
                transform   => sub {
                    $_ =~ s/gradle/.\/gradlew/ for(@{$_[0]->{build_commands}});
                }
            }
        ],
    },
    {
        name            => 'maven',
        build_file      => 'pom.xml',
        build_commands  => ['mvn package'],
        copy_commands   => [
            "mkdir -p $LAMBDA_DIR/base",
            "cp -r target/lib         $LAMBDA_DIR/base/",
            "cp -r target/classes/*   $LAMBDA_DIR/base/", # Resources are also in this folder
        ],
        flavours        => [
            {
                name        => 'wrapper',
                if          => sub { -f "$APP_DIR/mvnw" },
                transform   => sub {
                    $_ =~ s/mvn/.\/mvnw/ for(@{$_[0]->{build_commands}});
                }
            }
        ],
    },
);
# # # # # SUB DECLARATIONS
sub copyAppToLambda;
sub scriptDie(@);
sub execOrDie($);
sub setupModels;
sub setup();
sub fileToJson($);
sub deepMerge($$);
# # # # # MAIN
setup();
copyAppToLambda();
setupModels();
# # # # # SUBS
sub setup(){
    # Get regions needed
    my $askConfig = fileToJson('.ask/config');
    my $skillConfig = fileToJson('skill.json');
    my %allRegions = map {
        $_->{awsRegion}, 1
    } @{$askConfig->{deploy_settings}->{default}->{resources}->{lambda}};
    @REGIONS = sort keys %allRegions;
    @LOCALES = sort keys %{$skillConfig->{manifest}->{publishingInformation}->{locales}};
    $APP_DIR = $BASE_DIR unless -d $APP_DIR;
    for my $tool(@BUILD_TOOLS){
        if(-f "$APP_DIR/$tool->{build_file}"){
            %BUILD_TOOL = (%{$tool});
            for my $f(@{$BUILD_TOOL{flavours}}){
                if($f->{if}->()){
                    $BUILD_TOOL{flavour} = $f->{name};
                    $f->{transform}->(\%BUILD_TOOL);
                }
            }
            last;
        }
    }
    if(! %BUILD_TOOL){
        scriptDie("Could not find which build tool you are using.",
                  "Available tools are: ".join(", ", map { $_->{name} } @BUILD_TOOLS));
    }
    logg(
        "USING BUILD TOOL: $BUILD_TOOL{name} (".($BUILD_TOOL{flavour} || 'vanilla').")",
        "USING APP DIR   : $APP_DIR",
    );
}
sub copyAppToLambda {
    logg("Building App (".join('|', @{$BUILD_TOOL{build_commands}}).")");
    chdir $APP_DIR;
    execOrDie($_) for @{$BUILD_TOOL{build_commands}};
    if($BUILD_TOOL{copy_commands}){
        logg("Copying App to Lambda");
        remove_tree $LAMBDA_DIR;
        execOrDie($_) for @{$BUILD_TOOL{copy_commands}};
    }
    for my $region(@REGIONS){
        next if(-s "$LAMBDA_DIR/$region");
        symlink "$LAMBDA_DIR/base", "$LAMBDA_DIR/$region" or die "$!\n";
    }
}
sub setupModels {
    my $baseModel = fileToJson("$MODELS_DIR/base.json");
    for my $locale(@LOCALES){
        my $localeModel = {};
        if(-f "$MODELS_DIR/${locale}-overlay.json"){
            $localeModel = deepMerge($baseModel, fileToJson("$MODELS_DIR/${locale}-overlay.json"));
        }else{
            $localeModel = $baseModel;
        }
        open my $fh, ">", "$MODELS_DIR/${locale}.json" or die "$!";
        print $fh $JSON->encode($localeModel);
        close $fh or die "$!";
    }
}
# # # # # UTIL SUBS
sub scriptDie(@){
    print "ERROR: $_\n" for @_;
    exit 1;
}
sub execOrDie($){
    my $command = shift;
    my @log = `$command 2>&1`;
    my $exit = $? >> 8;
    chomp for @log;
    if($exit){
        scriptDie "Command failed: $command", @log;
    }
    return @log;
}
sub logg(@){
    print "SCRIPT: $_\n" for @_;
}
sub fileToJson($){
    my $file = shift;
    return $JSON->decode(do {
        open my $fh, "<", $file or die "$!\n";
        local $/;
        <$fh>;
    });
}
sub deepMerge($$){
    my ($a, $b) = @_;
    return $a unless defined $b;
    return $b unless defined $a;
    if(ref $a ne ref $b){
        die "Cannot merge incompatble types";
    }
    if(ref $a eq "HASH"){
        my $c = $a;
        $c->{$_} = deepMerge($a->{$_}, $b->{$_}) for keys %{$a};
        $c->{$_} ||= $b->{$_}                    for keys %{$b};
        return $c;
    }elsif(ref $a eq "ARRAY"){
        if(ref $a->[0] eq "HASH" and $a->[0]->{name}){
            my %hashA = map { ($_->{name}, $_) } @{$a};
            my %hashB = map { ($_->{name}, $_) } @{$b};
            my $hashC = deepMerge(\%hashA, \%hashB);
            return [values %{$hashC}];
        }else{
            return $b;
        }
    } else {
        return $b;
    }
}
