require 'bagit'

# Assemble FTK output into objects for Hypatia. 
# @example Process an FTK report and a directory of files
#  my_fedora_config = "/path/to/fedora.yml"
#  my_bag_dir = "/path/to/where/my/bags/should/be/created"
#  ftk_report = "/path/to/FTK_Report.xml"
#  file_dir = "/path/to/exported/ftk/file/directory"
#  hfo = HypatiaFileObjectAssembler.new(:fedora_config => my_fedora_config, :bag_destination => my_bag_dir)
#  hfo.process(ftk_report, file_dir)
class HypatiaFileObjectAssembler
  
  attr_accessor :ftk_report         # The FTK report to process
  attr_accessor :ftk_processor      # The FtkProcessor object used to parse the FTK report
  attr_accessor :file_dir           # Where should I copy the files from? 
  attr_accessor :bag_destination    # When I create BagIt packages, where should they go? 
  
  # @param [Hash] args 
  # @param [Hash[:fedora_config]] 
  def initialize(args={})
    @logger = Logger.new('logs/logfile.log')
    @logger.debug 'Initializing Hypatia File Object Assembler'
    
    if args[:fedora_config]
      ActiveFedora.init(args[:fedora_config])
    else
      ActiveFedora.init
    end
    
    setBagDestination(args)
  end
  
  # Determine where bags should be written and set the value of @bag_destination
  # @param [Hash] args the args that were passed to initialize this object
  def setBagDestination(args)
    if args[:bag_destination]
      @bag_destination = args[:bag_destination]
    else
      @bag_destination = "/tmp"
    end
  end
  
  # Process an FTK report and turn each of the files into fedora objects
  # @param [String] ftk_report the path to the FTK report
  # @param [String] file_dir the directory holding the files
  def process(ftk_report, file_dir)
    @logger.debug "ftk report = #{ftk_report}"
    @logger.debug "file_dir = #{file_dir}"
    @ftk_report = ftk_report
    raise "Directory #{file_dir} not found" unless File.directory? file_dir
    @file_dir = file_dir
    @ftk_processor = FtkProcessor.new(:ftk_report => @ftk_report, :logfile => @logger)
    @ftk_processor.files.each do |ftk_file|
      create_bag(ftk_file[1])
    end
  end
  
  # Create a bagit package for an FTK file
  # @param [FtkFile] The FTK file object 
  # @return [BagIt::Bag]
  # @example
  def create_bag(ff)
    raise "I can't create a bag without knowing where the files come from" unless @file_dir
    @logger.debug "Creating bag for #{ff.unique_combo}"
    bag = BagIt::Bag.new File.join(@bag_destination, "/#{ff.unique_combo}")
    descMeta = buildDescMetadata(ff)
    contentMeta = buildContentMetadata(ff)
    bag.add_file("descMetadata.xml") do |io|
      io.puts descMeta
    end
    bag.add_file("contentMetadata.xml") do |io|
      io.puts contentMeta
    end
    bag.add_file("rightsMetadata.xml") do |io|
      io.puts buildRightsMetadata(ff)
    end
    bag.add_file("RELS-EXT.xml") do |io|
      io.puts buildRelsExt(ff)
    end
    copy_payload(ff,bag)
    bag.manifest!
    @logger.info "Bag created at #{bag.bag_dir}"
    return bag
  end
  
  # Copy the payload file from the source destination to the bagit package
  # @param [FtkFile] ff FTK file object
  # @param [BagIt::Bag] bag The bagit directory destination
  def copy_payload(ff,bag)
    source_file = File.join(@file_dir,ff.export_path)
    @logger.error "Couldn't find file #{source_file} for bagging" unless File.file? source_file
    bag.add_file(ff.filename, source_file)
  end
  
  # Build a MODS record for the FtkFile 
  # @param [FtkFile] ff FTK file object
  # @return [Nokogiri::XML::Document]
  # @example document returned
  #  <?xml version="1.0"?>
  #  <mods:mods xmlns:mods="http://www.loc.gov/mods/v3">
  #   <mods:titleInfo>
  #     <mods:title>A Heartbreaking Work of Staggering Genius</mods:title>
  #   </mods:titleInfo>
  #   <mods:typeOfResource>Journal Article</mods:typeOfResource>
  #   <mods:physicalDescription>
  #     <mods:form>Punch Cards</mods:form>
  #   </mods:physicalDescription>
  #  </mods:mods>
  def buildDescMetadata(ff)
    @logger.debug "building desc metadata for #{ff.unique_combo} "
    builder = Nokogiri::XML::Builder.new do |xml|
      # Really, mods records should be in the mods namespace, 
      # but it makes it a bit of a pain to query them. 
      xml.mods('xmlns:mods' => "http://www.loc.gov/mods/v3") {
        xml.parent.namespace = xml.parent.namespace_definitions.first
        xml['mods'].titleInfo {
          xml['mods'].title_ ff.title
        }
        xml['mods'].typeOfResource_ ff.type
        xml['mods'].physicalDescription {
          xml['mods'].form_ ff.medium
        }
      }
    end
    builder.to_xml
  end
  
  # Build a contentMetadata datastream
  # @param [FtkFile] ff FTK file object
  # @return [Nokogiri::XML::Document]
  # @example document returned
  #  <?xml version="1.0"?>
  #  <contentMetadata type="born-digital" objectId="foofile.txt_9999">
  #    <resource data="metadata" id="analysis-text" type="analysis" objectId="????">
  #      <file size="504 B" format="WordPerfect 5.1" id="foofile.txt">
  #        <location type="filesystem">files/foofile.txt</location>
  #        <checksum type="md5">4E1AA0E78D99191F4698EEC437569D23</checksum>
  #        <checksum type="sha1">B6373D02F3FD10E7E1AA0E3B3AE3205D6FB2541C</checksum>
  #      </file>
  #    </resource>
  #  </contentMetadata>
  # @example calling this method
  #  @ff = FactoryGirl.build(:ftk_file)
  #  @hfo = HypatiaFileObjectAssembler.new(:fedora_config => @fedora_config)
  #  cm = @hfo.buildContentMetadata(@ff)
  #  doc = Nokogiri::XML(cm)
  #  doc.xpath("/contentMetadata/@type").to_s.should eql("born-digital")
  def buildContentMetadata(ff)
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.contentMetadata("type" => "born-digital", "objectId" => ff.unique_combo) {
        xml.resource("id" => "analysis-text", "type" => "analysis", "data" => "metadata", "objectId" => "????"){
          xml.file("id" => ff.filename, "format" => ff.filetype, "size" => ff.filesize) {
            xml.location("type" => "filesystem") {
              xml.text ff.export_path
            }
            xml.checksum("type" => "md5") {
              xml.text ff.md5
            }
            xml.checksum("type" => "sha1") {
              xml.text ff.sha1
            }
          }
        }
      }
    end    
    builder.to_xml
  end
  
  # Build rightsMetadata datastream
  # @param [FtkFile] ff FTK file object
  # @return [Nokogiri::XML::Document]
  def buildRightsMetadata(ff)
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.rightsMetadata("xmlns" => "http://hydra-collab.stanford.edu/schemas/rightsMetadata/v1", "version" => "0.1"){
        xml.access("type" => "discover"){
          xml.machine {
            xml.group "public"
          }
        }
        xml.access("type" => "read"){
          xml.machine {
            xml.group "public"
          }
        }
      }
    end
    builder.to_xml
  end
  
  # Build the RELS-EXT datastream
  # @param [FtkFile] ff FTK file object
  # @return [Nokogiri::XML::Document]
  # @example document returned
  #  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:hydra="http://projecthydra.org/ns/relations#" xmlns:rel="info:fedora/fedora-system:def/relations-external#" xmlns:fedora-model="info:fedora/fedora-system:def/model#">
  #    <rdf:Description rdf:about="foofile.txt_9999">
  #      <hydra:isGovernedBy rdf:resource="info:fedora/hypatia:fixture_xanadu_apo"/>
  #      <rel:isMemberOf rdf:resource="PARENT OBJECT GOES HERE"/>
  #      <rel:hasModel rdf:resource="OBJECT MODEL GOES HERE"/>
  #    </rdf:Description>
  #  </rdf:RDF>
  def buildRelsExt(ff)
    builder = Nokogiri::XML::Builder.new do |xml|
      xml.RDF("xmlns:rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
      "xmlns:fedora-model" => "info:fedora/fedora-system:def/model#", 
      "xmlns:rel"=>"info:fedora/fedora-system:def/relations-external#",
      "xmlns:hydra"=>"http://projecthydra.org/ns/relations#") {
        xml.parent.namespace = xml.parent.namespace_definitions.first
        xml['rdf'].Description("rdf:about" => ff.unique_combo) {
          xml['hydra'].isGovernedBy("rdf:resource" => "info:fedora/hypatia:fixture_xanadu_apo")
          xml['rel'].isMemberOf("rdf:resource" => "PARENT OBJECT GOES HERE")
          xml['rel'].hasModel("rdf:resource" => "OBJECT MODEL GOES HERE")
        }
      }
    end
    builder.to_xml
  end
  
end